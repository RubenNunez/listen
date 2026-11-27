//! The gRPC service: checks the device token and hands the calls to the manager.

use crate::activity::{Activity, Entry, Kind};
use crate::config::Config;
use crate::manager::Manager;
use crate::pairing::{device_for, PairError, Pairing};
use crate::tls::Identity;
use listen_router_proto::v1::router_server::{Router, RouterServer};
use listen_router_proto::v1::{
    AskEvent, AskRequest, CloseSessionRequest, CloseSessionResponse, DeliverRequest, DeliverResponse, Limits,
    OpenSessionRequest, OpenSessionResponse, PairRequest, PairResponse, SignedIn, StatusRequest, StatusResponse, Tool,
    ToolStatus,
};
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use tokio::net::TcpListener;
use tokio_stream::wrappers::{ReceiverStream, TcpListenerStream};
use tokio_stream::{Stream, StreamExt};
use tonic::transport::{Server, ServerTlsConfig};
use tonic::{Request, Response, Status};

/// What the router found out about a command-line tool when it started.
#[derive(Debug, Clone, Default)]
pub struct Found {
    pub found: bool,
    pub version: String,
}

pub struct RouterService {
    pub manager: Arc<Manager>,
    pub pairing: Arc<Mutex<Pairing>>,
    pub config: Arc<Mutex<Config>>,
    pub config_path: PathBuf,
    pub name: String,
    pub claude: Found,
    pub codex: Found,
    pub activity: Activity,
}

impl RouterService {
    /// Every call except `Pair` must carry the token of a paired device.
    fn check<T>(&self, request: &Request<T>) -> Result<(), Status> {
        let token = request
            .metadata()
            .get("authorization")
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "))
            .ok_or_else(|| Status::unauthenticated("pair this device with the router first"))?;
        if device_for(token, &self.config.lock().unwrap()).is_some() {
            Ok(())
        } else {
            Err(Status::unauthenticated("this device is not paired with the router"))
        }
    }
}

#[tonic::async_trait]
impl Router for RouterService {
    async fn pair(&self, request: Request<PairRequest>) -> Result<Response<PairResponse>, Status> {
        let request = request.into_inner();
        let mut config = self.config.lock().unwrap();
        let token = self.pairing.lock().unwrap().redeem(&request.code, &request.device_name, &mut config).map_err(
            |e| match e {
                PairError::Wrong => Status::permission_denied("wrong pairing code"),
                PairError::Expired => {
                    Status::failed_precondition("the pairing code has expired; make a new one on the router")
                }
                PairError::NoCode => {
                    Status::failed_precondition("no pairing code is waiting; make a new one on the router")
                }
            },
        )?;
        if let Err(error) = config.save(&self.config_path) {
            config.devices.pop();
            return Err(Status::internal(format!("the device could not be stored: {error}")));
        }
        self.activity.push(Entry::now(Kind::Paired).detail(&request.device_name));
        Ok(Response::new(PairResponse { device_token: token, router_name: self.name.clone() }))
    }

    async fn status(&self, request: Request<StatusRequest>) -> Result<Response<StatusResponse>, Status> {
        self.check(&request)?;
        let limits = self.manager.limits();
        Ok(Response::new(StatusResponse {
            router_version: env!("CARGO_PKG_VERSION").to_string(),
            tools: vec![
                ToolStatus {
                    tool: Tool::Claude as i32,
                    found: self.claude.found,
                    version: self.claude.version.clone(),
                    enabled: true,
                    signed_in: self.manager.signed_in() as i32,
                },
                ToolStatus {
                    tool: Tool::Codex as i32,
                    found: self.codex.found,
                    version: self.codex.version.clone(),
                    // Off unless the owner switched it on in the router's window (design, section 9).
                    enabled: self.manager.rules().codex_enabled && self.codex.found,
                    signed_in: SignedIn::Unknown as i32,
                },
            ],
            limits: Some(Limits {
                sessions_per_topic: limits.sessions_per_topic,
                sessions_total: limits.sessions_total,
                idle_seconds: limits.idle_seconds,
                silence_seconds: limits.silence_seconds,
            }),
            sessions: self.manager.infos(),
        }))
    }

    async fn open_session(
        &self,
        request: Request<OpenSessionRequest>,
    ) -> Result<Response<OpenSessionResponse>, Status> {
        self.check(&request)?;
        self.manager.open(request.into_inner()).map(Response::new)
    }

    async fn deliver(&self, request: Request<DeliverRequest>) -> Result<Response<DeliverResponse>, Status> {
        self.check(&request)?;
        let request = request.into_inner();
        let waiting = self.manager.deliver(&request.session_id, request.text)?;
        Ok(Response::new(DeliverResponse { waiting }))
    }

    type AskStream = Pin<Box<dyn Stream<Item = Result<AskEvent, Status>> + Send>>;

    async fn ask(&self, request: Request<AskRequest>) -> Result<Response<Self::AskStream>, Status> {
        self.check(&request)?;
        let request = request.into_inner();
        let events = self.manager.ask(&request.session_id, request.text).await?;
        Ok(Response::new(Box::pin(ReceiverStream::new(events).map(Ok))))
    }

    async fn close_session(
        &self,
        request: Request<CloseSessionRequest>,
    ) -> Result<Response<CloseSessionResponse>, Status> {
        self.check(&request)?;
        self.manager.close(&request.into_inner().session_id).await?;
        Ok(Response::new(CloseSessionResponse {}))
    }
}

/// Serves on the listener, encrypted with the router's own certificate, until `stop` resolves.
pub async fn serve(
    service: RouterService,
    listener: TcpListener,
    identity: &Identity,
    stop: impl Future<Output = ()>,
) -> Result<(), tonic::transport::Error> {
    let tls =
        ServerTlsConfig::new().identity(tonic::transport::Identity::from_pem(&identity.cert_pem, &identity.key_pem));
    Server::builder()
        .tls_config(tls)?
        .add_service(RouterServer::new(service))
        .serve_with_incoming_shutdown(TcpListenerStream::new(listener), stop)
        .await
}
