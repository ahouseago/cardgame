import gleam/dynamic
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Card {
  Attack
  Counter
  Rest
}

pub fn to_string(card: Card) {
  case card {
    Attack -> "attack"
    Counter -> "counter"
    Rest -> "rest"
  }
}

pub fn to_json(card: Card) -> json.Json {
  json.string(to_string(card))
}

pub fn maybe_to_json(card: Option(Card)) -> json.Json {
  case card {
    Some(card) -> to_json(card)
    None -> json.null()
  }
}

pub fn decode_json(card) {
  dynamic.string(card)
  |> result.then(fn(card_str) {
    case card_str {
      "attack" -> Ok(Attack)
      "counter" -> Ok(Counter)
      "rest" -> Ok(Rest)
      other ->
        Error([
          dynamic.DecodeError("attack | counter | rest", other, [
            "message", "card",
          ]),
        ])
    }
  })
}
