import gleam/bytes_builder
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import mist.{type Connection, type ResponseData}

type State =
  Dict(Int, mist.WebsocketConnection)

type ConnectionMsg {
  Create(mist.WebsocketConnection)
  Delete(Int)
  Broadcast(String)
}

pub fn main() {
  // These values are for the Websocket process initialized below
  let selector = process.new_selector()
  let assert Ok(state) = actor.start(dict.new(), handle_message)

  let not_found =
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_builder.new()))

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      case request.path_segments(req) {
        ["ws"] ->
          mist.websocket(
            request: req,
            on_init: on_init(state, selector),
            on_close: fn(_state) { io.println("goodbye!") },
            handler: handle_ws_message,
          )

        _ -> not_found
      }
    }
    |> mist.new
    |> mist.port(3000)
    |> mist.start_http

  process.sleep_forever()
}

fn on_init(state_subj, selector) {
  fn(conn) {
    actor.send(state_subj, Create(conn))
    #(state_subj, Some(selector))
  }
}

fn handle_message(
  msg: ConnectionMsg,
  state: State,
) -> actor.Next(ConnectionMsg, State) {
  case msg {
    Create(conn) -> {
      let new_state = dict.insert(state, dict.size(state), conn)
      actor.continue(new_state)
    }
    Delete(id) ->
      dict.delete(state, id)
      |> actor.continue
    Broadcast(text) -> {
      let assert Ok(_) =
        dict.values(state)
        |> list.try_each(fn(conn) { mist.send_text_frame(conn, text) })
      actor.continue(state)
    }
  }
}

fn handle_ws_message(state, conn, message: mist.WebsocketMessage(ConnectionMsg)) {
  case message {
    mist.Text("ping") -> {
      let assert Ok(_) = mist.send_text_frame(conn, "pong")
      actor.continue(state)
    }
    mist.Text(text) -> {
      io.println("Received message: " <> text)
      actor.send(state, Broadcast(text))
      actor.continue(state)
    }
    mist.Binary(_) -> {
      actor.continue(state)
    }
    mist.Custom(Broadcast(text)) -> {
      let assert Ok(_) = mist.send_text_frame(conn, text)
      actor.continue(state)
    }
    mist.Custom(_) -> {
      actor.continue(state)
    }
    mist.Closed | mist.Shutdown -> actor.Stop(process.Normal)
  }
}
