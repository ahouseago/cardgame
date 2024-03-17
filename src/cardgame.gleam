import gleam/bytes_builder
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import mist.{type Connection, type ResponseData}

type State =
  Dict(Int, mist.WebsocketConnection)

type ConnectionMsg {
  Create(mist.WebsocketConnection)
  Delete(Int)
  Receive(String)
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

type Message {
  Chat(Int, String)
  Broadcast(String)
}

// {
//   "type": "chat",
//   "message": {
//     "to": 2,
//     "text": "abc"
//   }
// }

fn decode_ws_message(text: String) -> Result(Message, List(dynamic.DecodeError)) {
  let type_decoder =
    dynamic.decode2(
      fn(t, msg) { #(t, msg) },
      dynamic.field("type", dynamic.string),
      dynamic.field("message", dynamic.dynamic),
    )
  let msg_with_type = json.decode(text, type_decoder)
  case msg_with_type {
    Ok(#("chat", msg)) ->
      msg
      |> dynamic.decode2(
        Chat,
        dynamic.field("to", dynamic.int),
        dynamic.field("text", dynamic.string),
      )
    Ok(#("broadcast", msg)) ->
      msg
      |> dynamic.decode1(Broadcast, dynamic.field("text", dynamic.string))
    Ok(#(found, _)) ->
      Error([dynamic.DecodeError("chat or broadcast", found, [])])
    Error(json.UnexpectedFormat(e)) -> Error(e)
    Error(json.UnexpectedByte(byte, _))
    | Error(json.UnexpectedSequence(byte, _)) ->
      Error([dynamic.DecodeError(byte, "", [])])
    Error(_) -> Error([dynamic.DecodeError("chat or broadcast", "", [])])
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
    Receive(text) -> {
      case decode_ws_message(text) {
        Ok(Chat(id, msg)) -> {
          // Send to ws if exists
          let assert Ok(_) =
            dict.get(state, id)
            |> result.then(fn(conn) {
              mist.send_text_frame(conn, msg)
              |> result.nil_error
            })
        }
        Ok(Broadcast(msg)) -> {
          // Send to all connected websockets
          let assert Ok(_) =
            dict.values(state)
            |> list.try_each(fn(conn) {
              mist.send_text_frame(conn, msg)
              |> result.nil_error
            })
        }
        Error(e) -> {
          io.debug(e)
          Error(Nil)
        }
      }
      actor.continue(state)
    }
  }
}

fn handle_ws_message(state, conn, message) {
  case message {
    mist.Text("ping") -> {
      let assert Ok(_) = mist.send_text_frame(conn, "pong")
      actor.continue(state)
    }
    mist.Text(text) -> {
      io.println("Received message: " <> text)
      actor.send(state, Receive(text))
      actor.continue(state)
    }
    mist.Binary(_) -> {
      actor.continue(state)
    }
    mist.Custom(_) -> {
      actor.continue(state)
    }
    mist.Closed | mist.Shutdown -> actor.Stop(process.Normal)
  }
}
