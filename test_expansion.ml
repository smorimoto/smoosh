open Test_prelude
open Fsh
open Expansion
open Printf

let rec fields_to_string = function
[] -> ""
| (Field(s)::rst) -> s ^ fields_to_string rst
| (QField(s)::rst) -> s ^ fields_to_string rst
| (WFS::rst) -> "<<WFS>>" ^ fields_to_string rst
| (FS::rst) -> "<<FS>>" ^ fields_to_string rst
| (SymField(c)::rst) -> "<<result of " ^ string_of_stmt c ^ ">>" ^ fields_to_string rst

(* RErr test_name expected got *)
type result = Ok | RErr of string * fields * fields

let check_expansion (test_name, s0, w_in, f_expected):result=
  (let (s1, f_out) = (full_expansion s0 w_in) in
  if (listEqualBy (=) f_out f_expected)
  then Ok
  else RErr( test_name, f_expected, f_out))

let os_var_x_foofoobarbar:ty_os_state=  ({ os_empty with shell_env = (Pmap.add "x" "foofoobarbar" os_empty.shell_env) })

let concrete = List.map (fun x -> Str x)

(* TODO: tests for variable assignment (will have to check ending state as well) *)
let expansion_tests:(string*ty_os_state*(entry)list*fields)list=
 ([
    ("plain string foo", os_empty, [S "foo"], concrete ["foo"]);
    ("expand tilde without username", { os_empty with shell_env = (Pmap.add "HOME" "/home/testuser" os_empty.shell_env) }, [K Tilde], concrete ["/home/testuser"]);
    ("normal paramater lookup of unset variable", os_empty, [K (Param("x", Normal))], []);
    ("paramter length of unset variable", os_empty, [K (Param("x", Length))], concrete ["0"]);

    ("ndefault parameter lookup on variable set to null replaces word", os_var_x_null, [K (Param("x", (NDefault [S "foo"])))], concrete ["foo"]);
    ("default parameter lookup on variable set to null is null", os_var_x_null, [K (Param("x", (Default [S "foo"])))], []);

    ("paramter length of set variable is the length of the string", os_var_x_set,  [K (Param("x", Length))], concrete ["3"]);
    ("parameter lookup on set variable returns the variable's value", os_var_x_set,[K (Param("x", (Default [S "foo"])))], concrete ["bar"]);
    ("alternate parameter lookup on set variable does not return the variable's value", os_var_x_set, [K (Param("x", (Alt [S "foo"])))], concrete ["foo"]);

    ("Single assignment", os_var_x_set, [S "bar"; K (Param("x", Normal))], concrete ["barbar"]);

    ("Single assignment", os_empty, [S "bar"; K (Param("x", (Assign [S "foo"])))], concrete ["barfoo"]);

    (* ${x=${x=foo}bar${x=baz}}
     * should return foobarfoo
     * x is set to foobarfoo at the end *)
    ("Nested assignment statements", os_empty,
      [K (Param("x", (Assign [K (Param("x", (Assign [S "foo"]))); S "bar"; K (Param("x", (Assign [S "baz"])))])))], concrete ["foobarfoo"]);

    (* ${y=${x:+foo}rab${x+oof}}
     * should return raboof
     * y is set to raboof and x is null at the end *)
    ("Alternate parameter lookups on a variable set to null", os_var_x_null,
      [K (Param("y", (Assign [K (Param("x", (NAlt [S "foo"]))); S "rab"; K (Param("x", (Alt [S "oof"])))])))], concrete ["raboof"]);

    (* ${x:-foo}bar${x-baz}
     * should return foobar
     * x is null at the end *)
    ("Default parameter lookups on a variable set to null", os_var_x_null,
      [K (Param("x", (NDefault [S "foo"]))); S "bar"; K (Param("x", (Default [S "baz"])))], concrete ["foobar"]);

    ("Field splitting parameter expansions, no quotes", os_empty,
      [K (Param("x", (Default [S "a b c"])))], concrete ["a"; "b"; "c"]);

    ("Field splitting parameter expansions, quoted", os_empty,
      [K (Param("x", (Default [DQ "a b c"])))], concrete ["a b c"]);

    ("Field splitting w/ IFS set to ' ,'; commas force field separation", os_ifs_spaceandcomma,
      [K (Param("x", (Assign [S ",b,c"])))], concrete [""; "b"; "c"]);

    (* This shows it is valid to represent the empty string with the empty list above *)
    ("Field splitting w/ IFS set to ' ,'; commas force field separation after parameter expansion", os_ifs_spaceandcomma,
      [S "a"; K (Param("x", (Assign [S ",b,c"])))], concrete ["a"; "b"; "c"]);

    ("Field splitting w/ IFS set to ' ,'; spaces do not force field separation", os_ifs_spaceandcomma,
      [K (Param("x", (Assign [S " b,c"])))], concrete ["b"; "c"]);

    ("Field splitting when IFS is just ','", os_ifs_comma,
      [S "a,b,c"], concrete ["a,b,c"]);

    ("Field splitting when IFS is just ','", os_ifs_comma,
      [S "a b c"], concrete ["a b c"]);

    ("Field splitting when IFS is just ','", os_ifs_comma,
      [S ",,foo,,"], concrete [",,foo,,"]);

    ("Field splitting when IFS is just ','", os_ifs_comma,
      [K (Param("x", (Default [S ",,foo,,"])))], concrete ["";"";"foo";""]);

    ("Field splitting ignores quote characters in expansion", os_empty,
      [S "\"this is three\""], concrete ["\"this is three\""]);

    ("String inside control quote does not field split", os_empty,
      [K (Quote [S "a b c"])], concrete ["a b c"]);

    ("Quoted paramter expansion does not field split", os_var_x_set_three,
      [K (Quote [K (Param("x", Normal))])], concrete ["\"this is three\""]);

    ("Quoted field is combined with adjacent fields when there is no ifs separators", os_var_x_set_three,
      [S "foo"; K (Quote [K (Param("x", Normal))]); S "bar"], concrete ["foo\"this is three\"bar"]);

    ("Quoted field is combined with adjacent fields when ifs separators are inside the quoted section", os_var_x_set_three,
      [S "foo"; K (Quote [S " "; K (Param("x", Normal)); S " "]); S "bar"], concrete ["foo \"this is three\" bar"]);

    ("Quoted field is a separate field when ifs separators are outside the quoted section", os_var_x_set_three,
      [S "foo"; F; K (Quote [K (Param("x", Normal))]); F; S "bar"], concrete ["foo"; "\"this is three\""; "bar"]);

    ("Quoted field is a separate field when ifs separators are outside the quoted section", os_var_x_set_three,
      [K (Param("y", Default [S "foo "])); K (Quote [K (Param("x", Normal))]); K (Param("y", Default [S " bar"]))], concrete ["foo"; "\"this is three\""; "bar"]);

    ("Simple arith test", os_empty,
      [K (Arith ([], [S "5 + 5"]))], concrete ["10"]);
    
    ("Shortest prefix", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Prefix, Shortest, [S "foo"])))], concrete ["foobarbar"]);

    ("Shortest prefix, empty *", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Prefix, Shortest, [S "*foo"])))], concrete ["foobarbar"]);

    ("Shortest prefix, empty all-consuming *", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Prefix, Shortest, [S "foo*"])))], concrete ["foobarbar"]);

    ("Longest prefix", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Prefix, Longest, [S "foo"])))], concrete ["foobarbar"]);

    ("Longest prefix, *", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Prefix, Longest, [S "*foo"])))], concrete ["barbar"]);

    ("Longest prefix, all-consuming *", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Prefix, Longest, [S "foo*"])))], concrete [""]);

    ("Shortest suffix", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Suffix, Shortest, [S "bar"])))], concrete ["foofoobar"]);

    ("Shortest suffix, empty *", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Suffix, Shortest, [S "bar*"])))], concrete ["foofoobar"]);

    ("Shortest suffix, empty all-consuming *", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Suffix, Shortest, [S "*bar"])))], concrete ["foofoobar"]);

    ("Longest suffix", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Suffix, Longest, [S "bar"])))], concrete ["foofoobar"]);

    ("Longest suffix, *", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Suffix, Longest, [S "bar*"])))], concrete ["foofoo"]);

    ("Longest suffix, all-consuming *", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Suffix, Longest, [S "*bar"])))], concrete [""]);

    ("Shortest prefix bracket [fgh]", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Prefix, Shortest, [S "[fgh]"])))], concrete ["oofoobarbar"]);

    ("Shortest prefix bracket [a-z][a-z][a-z]", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Prefix, Shortest, [S "[a-z][a-z][a-z]"])))], concrete ["foobarbar"]);

    ("Shortest prefix bracket [:alpha:]", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Prefix, Shortest, [S "[[:alpha:]]"])))], concrete ["oofoobarbar"]);

    ("Shortest prefix bracket [.f.]", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Prefix, Shortest, [S "[[.f.]]"])))], concrete ["oofoobarbar"]);

    ("Shortest prefix bracket [.g.]", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Prefix, Shortest, [S "[[.g.]]"])))], concrete ["foofoobarbar"]);

    ("Shortest prefix bracket [=f=]", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Prefix, Shortest, [S "[[=f=]]"])))], concrete ["oofoobarbar"]);

    ("Shortest prefix bracket [[.a.]-[.z.]]", os_var_x_foofoobarbar,
     [K (Param("x", Substring (Prefix, Shortest, [S "[[.a.]-[.z.]]"])))], concrete ["oofoobarbar"]);

    ("Error unset", os_empty,
     [K (Param("x", Error [S "uhoh"]))], concrete ["x:";"uhoh"]);
    ("NError unset", os_empty,
     [K (Param("x", NError [S "uhoh"]))], concrete ["x:";"uhoh"]);

    ("Error null", os_var_x_null,
     [K (Param("x", Error [S "uhoh"]))], concrete []);
    ("NError null", os_var_x_null,
     [K (Param("x", NError [S "uhoh"]))], concrete ["x:";"uhoh"]);

    ("Error nested arith", os_empty,
     [K (Param("x", Error [K (Arith ([], [S "1+1"]))]))], concrete ["x:";"2"]);
    ("NError nested arith", os_empty,
     [K (Param("x", Error [K (Arith ([], [S "1+1"]))]))], concrete ["x:";"2"]);
  ])

let reify = function
  | Str s -> s
  | Result c -> "<<result of " ^ string_of_stmt c ^ ">>"

let rec list_to_string = function		
  | [] -> ""		
  | [f] -> reify f		
  | f::l -> reify f ^ "<<FS>>" ^ (list_to_string l)

let run_tests () =
  let failed = ref 0 in
  print_endline "\n=== Running word expansion tests...";
  List.iter
    (fun t ->
      match check_expansion t with
      | Ok -> ()
      | RErr(name,expected,got) ->
         printf "%s failed: expected '%s' got '%s'\n"
                name (list_to_string expected) (list_to_string got);
         incr failed)
    expansion_tests;
  printf "=== ...ran %d word expansion tests with %d failures.\n\n" (List.length expansion_tests) !failed
