### void/i18n/dict — the shipped dictionaries: the fifteen schema error
### codes in :en (reproducing the core default-messages output byte for
### byte) and :ru. Contributed to :void.i18n/messages at :precedence 0 —
### an application's dictionary (default 100) overrides any key without
### naming a number, and `void plugins check` shows who contributed what.

(def en
  "Schema error texts, matching void/core/schema `default-messages`."
  {:void.schema/type "expected {expected}, got {value}"
   :void.schema/literal "expected exactly {expected}, got {value}"
   :void.schema/enum "expected one of {values}, got {value}"
   :void.schema/union "no union branch matched {value}"
   :void.schema/missing "required key is missing"
   :void.schema/unknown "unknown key in a closed map"
   :void.schema/key "invalid key {value}"
   :void.schema/min "expected at least {min}, got {value}"
   :void.schema/max "expected at most {max}, got {value}"
   :void.schema/min-length "expected length >= {min}, got {length}"
   :void.schema/max-length "expected length <= {max}, got {length}"
   :void.schema/pattern "{value} does not match pattern {pattern}"
   :void.schema/format "{value} is not a valid {format}"
   :void.schema/pred "predicate failed for {value}"
   :void.schema/peg "{value} does not match peg {source}"})

(def ru
  "Schema error texts in Russian."
  {:void.schema/type "ожидается {expected}, получено {value}"
   :void.schema/literal "ожидается ровно {expected}, получено {value}"
   :void.schema/enum "ожидается одно из {values}, получено {value}"
   :void.schema/union "ни один вариант объединения не подошёл: {value}"
   :void.schema/missing "обязательное поле отсутствует"
   :void.schema/unknown "неизвестный ключ в закрытой структуре"
   :void.schema/key "недопустимый ключ {value}"
   :void.schema/min "ожидается не меньше {min}, получено {value}"
   :void.schema/max "ожидается не больше {max}, получено {value}"
   :void.schema/min-length "ожидается длина не меньше {min}, получено {length}"
   :void.schema/max-length "ожидается длина не больше {max}, получено {length}"
   :void.schema/pattern "{value} не соответствует шаблону {pattern}"
   :void.schema/format "{value} — не корректное значение формата {format}"
   :void.schema/pred "значение {value} не прошло проверку"
   :void.schema/peg "{value} не соответствует грамматике {source}"})
