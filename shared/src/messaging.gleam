import card.{type Card}
import gleam/dynamic
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair

pub type Hand {
  Hand(attacks: Int, counters: Int, rests: Int)
}

pub type PlayerMatchState {
  PlayerMatchState(
    // Player ID
    id: Int,
    hand: Hand,
    chosen_card: Option(Card),
    health: Int,
    unresolved_card_choice: Option(List(Card)),
  )
}

pub type OpponentMatchState {
  OpponentMatchState(num_cards: Int, health: Int)
}

pub type EndState {
  Draw
  Victory(winner: Int)
}

pub type PlayerIdPair {
  PlayerIdPair(Int, Int)
}

pub type MatchState {
  ResolvingRound(PlayerIdPair, List(PlayerMatchState))
  Finished(PlayerIdPair, EndState)
}

pub type GamePhase {
  Idle
  Challenging(opponent_id: Int)
  InMatch(match_id: Int)
}

pub type RoundResult {
  MatchEnded(EndState)
  NextRound(you: PlayerMatchState, opponent: OpponentMatchState)
}

pub type IncomingMessage {
  Chat(to: Int, String)
  ChallengeRequest(target: Int)
  ChallengeResponse(challenger: Int, accepted: Bool)
  PlayCard(Card)
  PickCard(Card)
}

pub fn incoming_to_json(msg: IncomingMessage) {
  let #(t, message) = case msg {
    Chat(from, text) -> #(
      "chat",
      json.object([#("to", json.int(from)), #("text", json.string(text))]),
    )
    ChallengeRequest(target) -> #(
      "challenge",
      json.object([#("target", json.int(target))]),
    )
    ChallengeResponse(challenger, accepted) -> #(
      "challengeResponse",
      json.object([
        #("challenger", json.int(challenger)),
        #("accepted", json.bool(accepted)),
      ]),
    )
    PlayCard(card) -> #(
      "playCard",
      json.object([#("card", card.to_json(card))]),
    )
    PickCard(card) -> #("card", card.to_json(card))
  }
  |> pair.map_first(json.string)
  json.to_string(json.object([#("type", t), #("message", message)]))
}

pub type OutgoingMessage {
  Err(String)
  PhaseUpdate(GamePhase)
  Direct(from: Int, String)
  Broadcast(String)
  Challenge(from: Int)
  ChallengeAccepted
  RoundResult(RoundResult)
  Connected(id: Int)
}

/// msg_to_json converts an OutgoingMessage to a json string for sending over
/// the websocket.
pub fn msg_to_json(msg) {
  case msg {
    Err(text) -> #("error", json.string(text))
    Direct(from, text) -> #(
      "chat",
      json.object([#("from", json.int(from)), #("text", json.string(text))]),
    )
    Broadcast(text) -> #("broadcast", json.string(text))
    Challenge(from) -> #("challenge", json.object([#("from", json.int(from))]))
    ChallengeAccepted -> #("challengeAccepted", json.null())
    PhaseUpdate(phase) -> #(
      "status",
      json.object([#("phase", phase_to_json(phase))]),
    )
    RoundResult(result) -> #("result", result_to_json(result))
    Connected(id) -> #("connected", json.int(id))
  }
  |> pair.map_first(json.string)
}

fn phase_to_json(phase) {
  let #(t, detail) = case phase {
    Idle -> #("idle", json.null())
    Challenging(id) -> #("challenging", json.int(id))
    InMatch(id) -> #("inMatch", json.int(id))
  }
  json.object([#("phaseType", json.string(t)), #("phaseDetail", detail)])
}

fn phase_from_json(phase) {
  let phase_type =
    phase
    |> dynamic.field("phaseType", dynamic.string)
  case phase_type {
    Ok("idle") -> Ok(Idle)
    Ok("challenging") ->
      case dynamic.field("phaseDetail", dynamic.int)(phase) {
        Ok(id) -> Ok(Challenging(id))
        Error(err) -> Error(err)
      }
    Ok("inMatch") ->
      case dynamic.field("phaseDetail", dynamic.int)(phase) {
        Ok(id) -> Ok(InMatch(id))
        Error(err) -> Error(err)
      }
    Ok(other) ->
      Error([
        dynamic.DecodeError("unknown phase type in status update", other, [
          "message", "status", "phase",
        ]),
      ])
    Error(any) -> Error(any)
  }
}

pub fn encode(msg: OutgoingMessage) -> String {
  let #(t, message) = msg_to_json(msg)
  json.to_string(json.object([#("type", t), #("message", message)]))
}

pub fn result_to_json(result: RoundResult) -> json.Json {
  case result {
    MatchEnded(Draw) -> json.object([#("resultType", json.string("draw"))])
    MatchEnded(Victory(winner)) ->
      json.object([
        #("resultType", json.string("victory")),
        #("winner", json.int(winner)),
      ])
    NextRound(player, opponent) ->
      json.object([
        #(
          "player",
          json.object([
            #(
              "hand",
              json.object([
                #("attacks", json.int(player.hand.attacks)),
                #("counters", json.int(player.hand.counters)),
                #("rests", json.int(player.hand.rests)),
              ]),
            ),
            #("chosen_card", card.maybe_to_json(player.chosen_card)),
            #("health", json.int(player.health)),
            #("cardChoices", case player.unresolved_card_choice {
              Some(options) -> json.array(options, card.to_json)
              None -> json.null()
            }),
          ]),
        ),
        #(
          "opponent",
          json.object([
            #("cardCount", json.int(opponent.num_cards)),
            #("health", json.int(opponent.health)),
          ]),
        ),
      ])
  }
}

fn result_from_json(result) {
  let result_type =
    result
    |> dynamic.field("resultType", dynamic.string)
  case result_type {
    Ok("draw") -> Ok(RoundResult(MatchEnded(Draw)))
    Ok("victory") -> {
      let winner =
        result
        |> dynamic.field("winner", dynamic.int)
      case winner {
        Ok(winner_id) -> Ok(RoundResult(MatchEnded(Victory(winner_id))))
        Error(err) -> Error(err)
      }
    }
    _ ->
      todo as "this is probably next round, should I check for that explicitely?"
  }
}

// {
//   "type": "chat",
//   "message": {
//     "to": 2,
//     "text": "abc"
//   }
// }

pub fn decode_ws_message(
  text: String,
) -> Result(IncomingMessage, List(dynamic.DecodeError)) {
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
    Ok(#("challenge", msg)) ->
      msg
      |> dynamic.decode1(ChallengeRequest, dynamic.field("target", dynamic.int))
    Ok(#("challengeResponse", msg)) ->
      msg
      |> dynamic.decode2(
        ChallengeResponse,
        dynamic.field("challenger", dynamic.int),
        dynamic.field("accepted", dynamic.bool),
      )
    Ok(#("playCard", msg)) ->
      msg
      |> dynamic.decode1(PlayCard, dynamic.field("card", card.decode_json))
    Ok(#("pickCard", msg)) ->
      msg
      |> dynamic.decode1(PickCard, dynamic.field("card", card.decode_json))

    Ok(#(found, _)) ->
      Error([
        dynamic.DecodeError(
          "chat | challenge | challengeResponse | playCard | pickCard",
          found,
          [],
        ),
      ])
    Error(json.UnexpectedFormat(e)) -> Error(e)
    Error(json.UnexpectedByte(byte, _))
    | Error(json.UnexpectedSequence(byte, _)) ->
      Error([dynamic.DecodeError(byte, "", [])])
    Error(_) -> Error([dynamic.DecodeError("chat or broadcast", "", [])])
  }
}

pub type WsMsgError {
  IdNotFound(Int)
  InvalidRequest(reason: String)
  MsgTypeNotFound(List(dynamic.DecodeError))
}

pub fn err_to_string(err) {
  case err {
    IdNotFound(id) -> "ID " <> int.to_string(id) <> " not found"
    InvalidRequest(reason) -> "Invalid request: " <> reason
    _ -> "Unknown error occurred"
  }
}

/// msg_from_json decodes a JSON stringified OutgoingMessage.
pub fn msg_from_json(
  text: String,
) -> Result(OutgoingMessage, List(dynamic.DecodeError)) {
  let msg_with_type =
    text
    |> json.decode(dynamic.decode2(
      fn(t, msg) { #(t, msg) },
      dynamic.field("type", dynamic.string),
      dynamic.field("message", dynamic.dynamic),
    ))
  case msg_with_type {
    Ok(#("error", msg)) -> dynamic.decode1(Err, dynamic.string)(msg)
    Ok(#("chat", msg)) ->
      msg
      |> dynamic.decode2(
        Direct,
        dynamic.field("from", dynamic.int),
        dynamic.field("text", dynamic.string),
      )
    Ok(#("broadcast", msg)) -> dynamic.decode1(Broadcast, dynamic.string)(msg)
    Ok(#("challenge", msg)) ->
      msg
      |> dynamic.decode1(Challenge, dynamic.field("from", dynamic.int))
    Ok(#("challengeAccepted", _)) -> Ok(ChallengeAccepted)
    Ok(#("status", msg)) ->
      dynamic.decode1(PhaseUpdate, dynamic.field("phase", phase_from_json))(msg)
    Ok(#("result", msg)) -> result_from_json(msg)
    Ok(#("connected", msg)) -> dynamic.decode1(Connected, dynamic.int)(msg)

    Ok(#(found, _)) ->
      Error([
        dynamic.DecodeError(
          "error | chat | broadcast | challenge | challengeAccepted | status | result | connected",
          found,
          [],
        ),
      ])
    Error(json.UnexpectedFormat(e)) -> Error(e)
    Error(json.UnexpectedByte(byte, _))
    | Error(json.UnexpectedSequence(byte, _)) ->
      Error([dynamic.DecodeError(byte, "", [])])
    Error(_) -> Error([dynamic.DecodeError("chat or broadcast", "", [])])
  }
}

pub fn dynamic_err_to_string(errs: dynamic.DecodeErrors) -> String {
  list.fold(errs, "", fn(err_string, err) {
    let dynamic.DecodeError(expected, found, _) = err
    err_string <> "; expected: " <> expected <> ", found: " <> found
  })
}
