import gleam/int
import gleam/io
import gleam/list
import lustre
import lustre/attribute
import lustre/effect
import lustre/element
import lustre/element/html
import lustre/event
import lustre_websocket as ws
import messaging

type Model {
  Connected(socket: ws.WebSocket, id: Int, messages: List(String))
  Disconnected
}

type Msg {
  Connect
  WsConnected(ws.WebSocket)
  RecieveTextMessage(messaging.OutgoingMessage)
  Disconnect
  FailedToConnect
  Err(String)
  SendMessage(messaging.IncomingMessage)
  SendChatMessage
}

fn init(_flags) {
  #(Disconnected, effect.none())
}

fn close_reason_to_string(reason) {
  case reason {
    ws.Normal -> "normal"
    ws.UnexpectedTypeOfData -> "unexpected type of data"
    ws.AbnormalClose -> "abnormal close"
    ws.MessageTooBig -> "message too big"
    _ -> "other"
  }
}

fn init_ws() -> effect.Effect(Msg) {
  ws.init("ws://localhost:3000/ws", fn(event) {
    io.println("attempting to connect...")
    case event {
      ws.InvalidUrl -> {
        io.println("ws connect error: invalid url")
        FailedToConnect
      }
      ws.OnOpen(ws) -> WsConnected(ws)
      ws.OnTextMessage(message) ->
        case messaging.msg_from_json(message) {
          Ok(msg) -> RecieveTextMessage(msg)
          Error(any) -> {
            io.println("failed to decode websocket message:")
            io.debug(any)
            Err(messaging.dynamic_err_to_string(any))
          }
        }
      ws.OnBinaryMessage(bit_array) -> todo
      ws.OnClose(reason) -> {
        io.println(
          "ws: connection closed with reason " <> close_reason_to_string(reason),
        )
        Disconnect
      }
    }
  })
}

fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case model, msg {
    _, Connect -> #(model, init_ws())
    _, WsConnected(socket) -> #(
      Connected(socket: socket, id: 0, messages: []),
      effect.none(),
    )
    Connected(socket, id, msgs), RecieveTextMessage(msg) -> {
      case msg {
        messaging.Err(err_string) -> #(
          Connected(socket, id, [err_string, ..msgs]),
          effect.none(),
        )
        messaging.PhaseUpdate(phase) -> todo
        messaging.Direct(from, message) -> #(
          Connected(socket, id, [
            "from " <> int.to_string(from) <> ": " <> message,
            ..msgs
          ]),
          effect.none(),
        )
        messaging.Broadcast(message) -> #(
          Connected(socket, id, ["broadcast: " <> message, ..msgs]),
          effect.none(),
        )
        messaging.Challenge(from) -> #(
          Connected(socket, id, [
            int.to_string(from) <> " has challenged you!",
            ..msgs
          ]),
          effect.none(),
        )
        messaging.ChallengeAccepted -> todo
        messaging.RoundResult(result) -> todo
        messaging.Connected(id) -> #(Connected(socket, id, msgs), effect.none())
      }
    }
    _, Err(msg) -> {
      io.println("got error message: " <> msg)
      #(model, effect.none())
    }
    _, RecieveTextMessage(_) -> #(model, effect.none())
    _, Disconnect -> #(model, effect.none())
    _, FailedToConnect -> #(model, effect.none())
    Connected(socket, _, _), SendMessage(msg) -> #(
      model,
      ws.send(socket, messaging.incoming_to_json(msg)),
    )
    _, SendMessage(_) -> #(model, effect.none())
    Connected(socket, _, _), SendChatMessage -> #(
      model,
      ws.send(socket, messaging.incoming_to_json(chat_message(model))),
    )
    _, SendChatMessage -> #(model, effect.none())
  }
}

fn chat_message(model: Model) -> messaging.IncomingMessage {
  todo as "get the text and recipient from the model (currently isn't added)"
}

fn view(model: Model) {
  case model {
    Disconnected ->
      html.div([], [
        html.h1([], [element.text("Disconnected")]),
        html.button([event.on_click(Connect)], [
          element.text("Connect to server"),
        ]),
      ])
    Connected(_socket, id, msgs) ->
      html.body([], [
        html.h1([], [element.text("Welcome player " <> int.to_string(id))]),
        html.ul(
          [],
          list.map(msgs, fn(msg) { html.li([], [element.text(msg)]) }),
        ),
        html.form([event.on_submit(SendChatMessage)], [
          html.input([
            event.on_input(send_message(id, _)),
            attribute.placeholder("Enter your message..."),
          ]),
        ]),
      ])
  }
}

fn send_message(id, msg) {
  SendMessage(messaging.Chat(id, msg))
}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
