(* Scanner for the Boomslang Language *)

{

open Parser 

module StringMap = Map.Make(String)

let add_entry map pair = StringMap.add (fst pair) (snd pair) map

let reserved_word_to_token = List.fold_left add_entry StringMap.empty [
  (* Boolean operators *)
  ("not", NOT); ("or", OR); ("and", AND);
  (* Loops and conditionals *)
  ("loop", LOOP); ("while", WHILE); ("if", IF); ("elif", ELIF); ("else", ELSE);
  (* Words related to functions and classes *)
  ("def", DEF); ("class", CLASS); ("self", SELF);
  ("return", RETURN); ("returns", RETURNS);
  ("static", STATIC); ("required", REQUIRED); ("optional", OPTIONAL);
  (* Primitive data types *)
  ("int", INT); ("long", LONG); ("float", FLOAT); ("boolean", BOOLEAN);
  ("char", CHAR); ("string", STRING); ("void", VOID);
  (* Default keyword for intitializing arrays *)
  ("default", DEFAULT);
]

let llvm_illegal_chars = [
  ("%", "pct"); ("&", "amp"); ("\\$", "dol"); ("@", "at"); ("!", "excl");
  ("#", "pound"); ("\\^", "caret"); ("\\*", "star"); ("/", "slash");
  ("~", "tilde"); ("\\?", "qstn"); (">", "gt"); ("<", "lt"); (":", "col");
  ("=", "eq");
]

let replace input_str illegal_char = Str.global_replace (Str.regexp (fst illegal_char)) (snd illegal_char) input_str
let replace_illegal_chars str = List.fold_left replace str llvm_illegal_chars

let convert_slashes str = 
  let str = Str.matched_string str in
  let orig_len = String.length str in
  let new_len = orig_len / 2 in
  String.sub str 0 new_len

let strip_firstlast str =
  if String.length str <= 2 then ""
  else String.sub str 1 ((String.length str) - 2)

(* In ocaml 4.08+ you could write let tab_count_stack = Stack.of_seq (List.to_seq [0]) *)
let tab_count_stack = Stack.create ()
let add_zero_to_stack = (Stack.push 0 tab_count_stack); ()
let token_queue = Queue.create ()

let rec enqueue_dedents n = if n > 0 then (Queue.add DEDENT token_queue; (enqueue_dedents (n-1)))

let rec enqueue_indents n = if n > 0 then (Queue.add INDENT token_queue; (enqueue_indents (n-1)))

let count_tabs str = if String.contains str '\t' then String.length str - String.index str '\t' else 0
}


(* Class names in Boomslang must start with a capital letter,
   to distinguish them from identifiers, which must begin
   with a lowercase letter *)
let class_name = ['A'-'Z']['a'-'z' 'A'-'Z']*
let int_literal = ['0'-'9']+

rule tokenize = parse
  [' ' '\r'] { tokenize lexbuf }
(* Mathematical operations *)
| '+' { PLUS }
| '-' { MINUS }
| '*' { TIMES }
| '/' { DIVIDE }
| '%' { MODULO }
(* Assignment operators *)
| '=' { EQ }
| "+=" { PLUS_EQ }
| "-=" { MINUS_EQ }
| "*=" { TIMES_EQ }
| "/=" { DIVIDE_EQ }
(* Comparison operators *)
| "==" { DOUBLE_EQ }
| "!=" { NOT_EQ }
| ">" { GT }
| "<" { LT }
| ">=" { GTE }
| "<=" { LTE }
(* Multi-line comments *)
| ['\n']+[' ' '\t']*"/#" { multi_comment lexbuf }
| "/#" { multi_comment lexbuf }
(* Misc. punctuation *)
| '(' { LPAREN }
| ')' { RPAREN }
| '[' { LBRACKET }
| ']' { RBRACKET }
| ':' { COLON }
| '.' { PERIOD }
| ',' { COMMA }
| '_' { UNDERSCORE }
| "NULL" { NULL }
(* Literal definitions *)
| int_literal as lit { INT_LITERAL(int_of_string lit) }
| int_literal"L" as lit {
    LONG_LITERAL(Int64.of_string (String.sub lit 0 (String.length lit - 1)))
}
| ['0'-'9']+('.'['0'-'9']+)? | '.'['0'-'9']+ as lit { FLOAT_LITERAL(lit) }
| "true" { BOOLEAN_LITERAL(true) }
| "false" { BOOLEAN_LITERAL(false) }
(* Char literals are single quotes followed by any single character
   followed by a single quote *)
| '\'' [' '-'~'] '\'' as lit { CHAR_LITERAL( (strip_firstlast lit).[0] ) }
(* String literals in Boomslang cannot contain double quotes or newlines.
   String literals are a " followed by any non newline or double quote
   followed by " regex copied from CORAL*)
|  '"' [^'"''\\']* ('\\'_[^'"''\\']* )* '"' as lit { let stripped = (strip_firstlast lit) in let fix_slashes = Str.global_substitute (Str.regexp "[\\]+") convert_slashes stripped in STRING_LITERAL(fix_slashes)}
(* Syntactically meaningful whitespace - tabs for indentation only *)
(* Either a single-line comment appears on a line by itself, in which case
   we ignore that line completely, or else it appears at the end of the line,
   in which case we ignore everything after the # before the \n *)
| (['\n']+[' ' '\t']*('#'[^'\n']*))* { tokenize lexbuf }
| ('#'[^'\n']*)?(['\n']+['\t']* as newlines_and_tabs) {
  let num_tabs = (count_tabs newlines_and_tabs) in
  if (Stack.top tab_count_stack) == num_tabs then
    NEWLINE
  else if (Stack.top tab_count_stack) > num_tabs then
    ((enqueue_dedents ((Stack.pop tab_count_stack) - num_tabs); Stack.push num_tabs tab_count_stack); NEWLINE)
  else
    ((enqueue_indents (num_tabs - (Stack.top tab_count_stack)); Stack.push num_tabs tab_count_stack); NEWLINE)
}
(* User defined types, i.e. class names *)
| class_name as t { CLASS_NAME(t) }
(* If we see a lowercase letter followed by any letters or digits,
   it could either be the name of a primitive type (e.g. int), or
   a reserved word (e.g. class) or an identifier for a variable. *)
| ['a'-'z']['a'-'z' 'A'-'Z' '0'-'9' '_']* as possible_id {
    if StringMap.mem possible_id reserved_word_to_token
      then StringMap.find possible_id reserved_word_to_token
    else
      IDENTIFIER(possible_id)
  }
| ['+' '-' '%' '&' '$' '@' '!' '#' '^' '*' '/' '~' '?' '>' '<' ':' '=']+ as lit {
  (* convert the weird chars to simpler strings so avoid any LLVM errors later on. *)
  OBJ_OPERATOR((replace_illegal_chars lit))
}
| '_'['+' '-' '%' '&' '$' '@' '!' '#' '^' '*' '/' '~' '?' '>' '<' ':' '=']+ as lit {
  (* convert the weird chars to simpler strings so avoid any LLVM errors later on. *)
  OBJ_OPERATOR_METHOD_NAME((replace_illegal_chars lit))
}
(* Automatically add a NEWLINE to end of all files.
   All statements in Boomslang must end in a NEWLINE, such that
   ordinarily all valid programs must have a blank line at the end.
   But since this is easy to forget, we automatically add a blank line
   here in case the user forgets. *)
| eof { (Queue.add EOF token_queue); NEWLINE }
| _ as c { raise (Failure("Illegal character: " ^ Char.escaped c)) }


and multi_comment = parse
  "#/" { tokenize lexbuf }
| _ { multi_comment lexbuf }

{
let read_next_token lexbuf =
  if Queue.is_empty token_queue then tokenize lexbuf else Queue.take token_queue
}

