fn main() -> Result<(), Box<dyn std::error::Error>> {
    // The protobuf compiler comes with the build, so nobody has to install it.
    std::env::set_var("PROTOC", protoc_bin_vendored::protoc_bin_path()?);
    let root = "../../../proto";
    let file = format!("{root}/listen/router/v1/router.proto");
    println!("cargo:rerun-if-changed={file}");
    tonic_prost_build::configure()
        .build_client(true)
        .build_server(true)
        .compile_protos(&[file], &[root.to_string()])?;
    Ok(())
}
