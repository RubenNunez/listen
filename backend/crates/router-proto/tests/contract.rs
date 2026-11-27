use listen_router_proto::v1::{ask_event, AskEvent, Tool};
use prost::Message;

#[test]
fn ask_event_carries_one_kind() {
    let event = AskEvent { kind: Some(ask_event::Kind::Text("a".into())) };
    let decoded = AskEvent::decode(event.encode_to_vec().as_slice()).unwrap();
    assert_eq!(decoded, event);
}

#[test]
fn tool_numbers_are_fixed() {
    assert_eq!(Tool::Claude as i32, 1);
    assert_eq!(Tool::Codex as i32, 2);
}
