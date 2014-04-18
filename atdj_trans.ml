open Printf
open Atdj_names
open Atdj_env
open Atdj_util

(* Calculate the JSON representation of an ATD type.
 *
 * Values of sum types t are encoded as either Strings or two-element
 * JSONArrays, depending upon the arity of the particular constructor.
 * A nullary constructor C is denoted by the String "C", whilst
 * an application of a unary constructor C to an ATD value v is denoted by the
 * JSONArray ["C", <v>], where <v> is the JSON representation of v.
 *
 * Option types other than in optional fields (e.g. '?foo: int option')
 * are not supported.
 *)
let json_of_atd env atd_ty =
  let atd_ty = norm_ty ~unwrap_option:true env atd_ty in
  match atd_ty with
    | `Sum    _              (* Either a String or a two element JSONArray *)
    | `Record _ -> "JSONObject"
    | `List   _ -> "JSONArray"
    | `Name (_, (_, ty, _), _) ->
        (match ty with
           | "bool"   -> "boolean"
           | "int"    -> "int"
           | "float"  -> "double"
           | "string" -> "String"
           | _        -> assert false
        )
    | x -> type_not_supported x

(* Calculate the method name required to extract the JSON representation of an
 * ATD value from either a JSONObject or a JSONArray ("get", "opt",
 * "getInt", "optInt", ...)
 *)
let get env atd_ty opt =
  let atd_ty = norm_ty ~unwrap_option:true env atd_ty in
  let prefix = if opt then "opt" else "get" in
  let suffix =
    match atd_ty with
      | `Sum _ -> ""
      | _ -> String.capitalize (json_of_atd env atd_ty) in
  prefix ^ suffix

let extract_from_edgy_brackets s =
  Str.global_replace
    (Str.regexp "^[^<]*<\\|>[^>]*$") "" s
(*
extract_from_edgy_brackets "ab<cd<e>>f";;
- : string = "cd<e>"
*)

(* Assignment with translation.  Suppose that atd_ty is an ATD type, with
 * corresponding Java and (Javafied) JSON types java_ty and json_ty. Then this
 * function assigns to a variable `dst' of type java_ty from a variable `src' of
 * type `json_ty'.
 *)
let rec assign env opt_dst src java_ty atd_ty indent =
  let atd_ty = norm_ty env atd_ty in
  match opt_dst with
  | None ->
      (match atd_ty with
       | `Sum _ ->
           sprintf "Factory.make(%s)" src
       | `Record _ ->
           sprintf "new %s(%s)" java_ty src
       | `Name (_, (_, ty, _), _) ->
           (match ty with
            | "bool" | "int" | "float" | "string" -> src
            | _  -> assert false
           )
       | x -> type_not_supported x
      )
  | Some dst ->
      (match atd_ty with
       | `Sum _ ->
           sprintf "%s%s = %sFactory.make(%s);\n" indent dst java_ty src
       | `Record _ ->
           sprintf "%s%s = new %s(%s);\n" indent dst java_ty src
       | `List (_, sub_ty, _) ->
           let java_sub_ty = (*ahem*) extract_from_edgy_brackets java_ty in
           let sub_expr = assign env None "tmp" java_sub_ty sub_ty "" in

           sprintf "%s%s = new %s();\n" indent dst java_ty
           ^ sprintf "%sfor (int i = 0; i < %s.length(); ++i) {\n" indent src

           ^ sprintf "%s  %s tmp = %s.%s(i);\n" indent
             (json_of_atd env sub_ty) src (get env sub_ty false)

           ^ sprintf "%s  %s.add(%s);\n" indent
             dst sub_expr
           ^ sprintf "%s}\n" indent

       | `Name (_, (_, ty, _), _) ->
           (match ty with
            | "bool" | "int" | "float" | "string" ->
                sprintf "%s%s = %s;\n" indent dst src
            | _  -> assert false
           )
       | x -> type_not_supported x
      )

(* Assign from an object field, with support for optional fields.  The are two
 * kinds of optional fields: `With_default (~) and `Optional (?).  For both
 * kinds, we return the following values if the field is absent:
 *
 *   bool   -> false
 *   int    -> 0
 *   float  -> 0.0
 *   string -> ""
 *   list   -> []
 *   option -> None
 *
 * Optional fields of record and sum types are not supported. They are
 * treated as required fields.
 *
 * Fields of the `Optional kind extend this behaviour by automatically lifting
 * values of type t to option t by wrapping within a `Some'.
 * Hence `Optional may only be applied to fields of type option t.
 * Note that absent fields are still
 * assigned `None', as before.
 *
 * For `With_default fields, of types bool, int, float, string and list, we use
 * the org.json opt methods to extract the field.  These methods already return
 * the appropriate defaults if field is absent.  For option types, we manually
 * check for the field and manually create a default.  If the field is present,
 * then we wrap its values as necessary.
 *)
let assign_field env
    (`Field (loc, (atd_field_name, kind, annots), atd_ty)) java_ty =
  let json_field_name = atd_field_name in
  let field_name = name_field atd_field_name annots in
  (* Check whether the field is optional *)
  let is_opt =
    match kind with
      | `Optional | `With_default -> true
      | `Required -> false in
  let src = sprintf "jo.%s(\"%s\")" (get env atd_ty is_opt) json_field_name in
  if not is_opt then
    assign env (Some field_name) src java_ty atd_ty "    "
  else
    let mk_else = function
      | Some default ->
          sprintf "    } else {\n    %s = %s;\n    }\n"
            field_name default
      | None ->
          "    }\n"
    in
    let opt_set_default =
      match kind with
      | `With_default ->
          (match norm_ty ~unwrap_option:true env atd_ty with
           | `Name (_, (_, name, _), _) ->
               (match name with
                | "bool" -> mk_else (Some "false")
                | "int" -> mk_else (Some "0")
                | "float" -> mk_else (Some "0.0")
                | "string" -> mk_else (Some "\"\"")
                | _ -> mk_else None (* TODO: fail if no default is provided *)
               )
           | `List _ ->
               (* java_ty is supposed to be of the form "ArrayList<...>" *)
               mk_else (Some (sprintf "new %s()" java_ty))
           | _ ->
               mk_else None (* TODO: fail if no default is provided *)
          )
      | _ ->
          mk_else None
    in
    let atd_ty = norm_ty ~unwrap_option:true env atd_ty in
    sprintf "    if (jo.has(\"%s\")) {\n" json_field_name
    ^ assign env (Some field_name) src java_ty atd_ty "      "
    ^ opt_set_default


(* Generate a toString command *)
let rec to_string env id atd_ty indent =
  let atd_ty = norm_ty env atd_ty in
  match atd_ty with
    | `List (_, atd_sub_ty, _) ->
          sprintf "%sstr += \"[\";\n" indent
        ^ sprintf "%sfor (int i = 0; i < %s.size(); ++i) {\n" indent id
        ^ to_string env (id ^ ".get(i)") atd_sub_ty (indent ^ "  ")
        ^ sprintf "%s  if (i < %s.size() - 1)\n" indent id
        ^ sprintf "%s    str += \",\";\n" indent
        ^ sprintf "%s}\n" indent
        ^ sprintf "%sstr += \"]\";\n" indent
    | `Name (_, (_, "string", _), _) ->
        (* TODO Check that this is the correct behaviour *)
        sprintf
          "%sstr += \"\\\"\" + Util.escape(String.valueOf(%s)) + \"\\\"\";\n"
          indent id
    | `Name _ ->
        sprintf "%sstr += String.valueOf(%s);\n" indent id
    | _ ->
        sprintf "%sstr += %s.toString();\n" indent id

(* Generate a toString command for a record field. *)
let to_string_field env = function
  | (`Field (loc, (atd_field_name, kind, annots), atd_ty)) ->
      let json_field_name = atd_field_name in
      let field_name = name_field atd_field_name annots in
      let atd_ty = norm_ty ~unwrap_option:true env atd_ty in
      (* In the case of an optional field, create a predicate to test whether
       * the field has its default value. *)
      let pred =
        let is_opt =
          match kind with
            | `Optional | `With_default -> true
            | `Required -> false in
        if is_opt then
          Some (sprintf "%s != null" field_name)
        else
          None
      in
      let (prefix, suffix, indent) =
        match pred with
          | Some p ->  (sprintf "    if (%s) {\n" p, "    }\n", "      ")
          | None   ->  ("", "", "    ") in
        prefix
      ^ sprintf "%sstr += \"\\\"%s\\\":\";\n" indent json_field_name
      ^ to_string env field_name atd_ty indent
      ^ sprintf "%sstr += \",\";\n" indent
      ^ suffix

(* Generate a javadoc comment *)
let javadoc loc annots indent =
  let from_inline_text text = indent ^ " * " ^ text ^ "\n" in
  (* Assume that code is the name of a field that is defined
     in the same class *)
  let from_inline_code code = indent ^ " * {@link #" ^ code ^ "}\n" in
  let from_doc_para acc para =
    List.fold_left
      (fun acc -> function
         | `Text text -> (from_inline_text text) :: acc
         | `Code code -> (from_inline_code code) :: acc
      )
      acc
      para in
  let from_doc = function
    | `Text blocks ->
        List.fold_left
          (fun acc -> function
             | `Paragraph para -> from_doc_para acc para
             | `Pre _ -> failwith "Preformatted doc blocks are not supported"
          )
          []
          blocks in
  (match Ag_doc.get_doc loc annots with
     | Some doc ->
         let header = indent ^ "/**\n" in
         let footer = indent ^ " */\n" in
         let body   =
           String.concat "" (List.rev (from_doc doc)) in
         header ^ body ^ footer
     | None     -> ""
  )


(* ------------------------------------------------------------------------- *)
(* Translation of ATD types into Java types *)

(* For option, sum and record types, we generate a Java class.  Each such class
 * implements the following interface:
 *
 *  interface Atdj {
 *    String toString();
 *  }
 *
 * The toString() method outputs a JSON representation of the
 * associated value.
 *
 * Each class also has a String constructor for a JSON string as well as a
 * constructor from the corresponding org.json type (see json_of_atd, above).
 *
 * We do not generate classes for types bool, int, float, string and list;
 * instead we `inline' these types directly into the class in which they
 * occur.  We do this so that the Java programmer can access such values
 * directly, thereby avoiding the overhead of having to manually unbox each such
 * value upon access.
 *)

let open_class env cname =
  let out = open_out (env.package_dir ^ "/" ^ cname ^ ".java") in
  fprintf out "\
// Automatically generated; do not edit
package %s;
import java.util.ArrayList;
import org.json.*;
import java.lang.Math;

"
    env.package;
  out

let rec trans_module env items = List.fold_left trans_outer env items

and trans_outer env (`Type (_, (name, _, _), atd_ty)) =
  match unwrap atd_ty with
    | `Sum _ as s ->
        trans_sum name env s
    | `Record _ as r ->
        trans_record name env r
    | `Name (_, (_, name, _), _) ->
        (* Don't translate primitive types at the top-level *)
        env
    | x -> type_not_supported x

(* Translation of sum types.  For a sum type
 *
 *   type t = Foo | Bar,
 *
 * we generate:
 *
 * 1. An marker interface
 * 2. A class for each constructor (i.e. Foo and Bar), implementing the marker
 *    interface.
 * 3. A factory class with a static `make' method.
 *    This method accepts a JSON parameter
 *    corresponding to a t, and instantiates the appropriate class from (2).
 *)
and trans_sum my_name env (`Sum (loc, vars, annots)) =
  (* Interface *)
  let ifc_name = Atdj_names.to_class_name my_name in
  let ifc_out = open_class env ifc_name in
  output_string ifc_out (javadoc loc annots "");
  fprintf ifc_out "public interface %s extends Atdj {\n" ifc_name;
  fprintf ifc_out "}\n";
  close_out ifc_out;
  let env = { env with types = (`Interface ifc_name) :: env.types; } in
  (* Constructors *)
  (* Javadoc doesn't seem to be used here, so omit for now *)
  let (env, names, _) = List.fold_left
    (fun (env, names, count) -> function
       | `Variant (_, (var_name, _), atd_type_expr_opt) ->
           let (env, var_class_name) =
             Atdj_names.freshen env (Atdj_names.to_class_name var_name) in
           let out = open_class env var_class_name in
           fprintf out "public class %s implements %s {\n"
             var_class_name ifc_name;
           let env =
             (match atd_type_expr_opt with
                | None ->
                    fprintf out "  %s() { }\n" var_class_name;
                    fprintf out "\n";
                    fprintf out "  public String toString() {\n";
                    fprintf out "    return \"\\\"%s\\\"\";\n" var_name;
                    fprintf out "  }\n";
                    fprintf out "\n";
                    { env with
                        types = `Class (var_class_name, []) :: env.types;
                        sub_types = (var_class_name, ifc_name) :: env.sub_types
                    }
                | Some atd_ty ->
                    let (java_ty, env) = trans_inner env atd_ty in
                    fprintf out "  %s(%s value) throws JSONException {\n"
                      var_class_name (json_of_atd env atd_ty);
                    fprintf out "%s\n"
                      (assign env (Some "this.value") "value" java_ty atd_ty
                         "    ");
                    fprintf out "  }\n";
                    fprintf out "\n";
                    fprintf out "  public String toString() {\n";
                    fprintf out "    String str = \"\";\n";
                    fprintf out "    str += \"[\\\"%s\\\",\";\n" var_name;
                    fprintf out "    %s"
                      (to_string env "value" atd_ty "");
                    fprintf out "    str += \"]\";\n";
                    fprintf out "    return str;\n";
                    fprintf out "  }\n";
                    fprintf out "\n";
                    fprintf out "  public final %s value;\n" java_ty;
                    { env with
                        types = `Class (var_class_name, ["value", java_ty])
                                :: env.types;
                        sub_types = (var_class_name, ifc_name)
                                    :: env.sub_types
                    }
             ) in
           fprintf out "}\n";
           close_out out;
           (env, (var_name, var_class_name) :: names, succ count)
       | `Inherit _ -> assert false
    )
    (env, [], 1) vars in
  (* Factory class *)
  let fact_name = Atdj_names.to_class_name (my_name ^ "Factory") in
  let fact_out = open_class env fact_name in
  fprintf fact_out "/**\n";
  fprintf fact_out " * Construct objects of type %s.\n" my_name;
  fprintf fact_out " */\n";
  fprintf fact_out "public class %s {\n" fact_name;
  fprintf fact_out "  public static %s make(String s) throws JSONException {\n"
    ifc_name;
  fprintf fact_out "    try {\n";
  fprintf fact_out "      return make(new JSONArray(s));\n";
  fprintf fact_out "    } catch (Exception e) {\n";
  fprintf fact_out "      // Could not parse as JSONArray, so try as string\n";
  fprintf fact_out "      return make((Object)Util.unescapeString\
                                                (Util.parseJSONString(s)));\n";
  fprintf fact_out "    }\n";
  fprintf fact_out "  }\n";
  fprintf fact_out "\n";
  fprintf fact_out "  static %s make(Object o) throws JSONException {\n"
    ifc_name;
  fprintf fact_out "    String tag = Util.tag(o);\n";
  List.iter
    (function
       | `Variant (_, (var_name, _), type_expr_opt) ->
           (match type_expr_opt with
              | None ->
                  fprintf fact_out "    if (tag.equals(\"%s\"))\n" var_name;
                  fprintf fact_out "      return new %s();\n"
                    (List.assoc var_name names)
              | Some t ->
                  fprintf fact_out "    if (tag.equals(\"%s\"))\n" var_name;
                  fprintf fact_out "      return new %s(((JSONArray)o).%s(1));\n"
                    (List.assoc var_name names)
                    (get env t false);
           )
       | `Inherit _ -> assert false
    )
    vars;
  fprintf fact_out "    throw new JSONException(\"Invalid tag: \" + tag);\n";
  fprintf fact_out "  }\n";
  fprintf fact_out "}\n";
  close_out fact_out;
  env

(* Translate a record into a Java class.  Each record field becomes a field
 * within the class.
 *)
and trans_record my_name env (`Record (loc, fields, annots)) =
  (* Remove `Inherit values *)
  let fields = List.map
    (function
       | `Field _ as f -> f
       | `Inherit _ -> assert false
    )
    fields in
  (* Translate field types *)
  let (java_tys, env) = List.fold_left
    (fun (java_tys, env) -> function
       | `Field (_, (field_name, _, annots), atd_ty) ->
           let field_name = name_field field_name annots in
           let (java_ty, env) = trans_inner env (unwrap_option env atd_ty) in
           ((field_name, java_ty) :: java_tys, env)
    )
    ([], env) fields in
  let java_tys = List.rev java_tys in
  (* Output Java class *)
  let class_name = Atdj_names.to_class_name my_name in
  let out = open_class env class_name in
  (* Javadoc *)
  output_string out (javadoc loc annots "");
  fprintf out "public class %s implements Atdj {\n" class_name;
  fprintf out "  /**\n";
  fprintf out "   * Construct from a JSON string.\n";
  fprintf out "   */\n";
  fprintf out "  public %s(String s) throws JSONException {\n" class_name;
  fprintf out "    this(new JSONObject(s));\n";
  fprintf out "  }\n";
  fprintf out "\n";
  fprintf out "  %s(JSONObject jo) throws JSONException {\n" class_name;
  let env = List.fold_left
    (fun env (`Field (loc, (field_name, _, annots), _) as field) ->
      let field_name = name_field field_name annots in
      let cmd = assign_field env field (List.assoc field_name java_tys) in
      fprintf out "%s" cmd;
      env
    )
    env fields in
  fprintf out "  }\n";
  fprintf out "\n";
  fprintf out "  public String toString() {\n";
  fprintf out "    String str = \"{\";\n";
  List.iter (fun field -> output_string out (to_string_field env field)) fields;
  fprintf out "    str = str.replaceAll(\",\\n$\", \"\\n\");\n";
  fprintf out "    str += \"}\";\n";
  fprintf out "    return str;\n";
  fprintf out "  }\n";
  fprintf out "\n";
  List.iter
    (function `Field (loc, (field_name, _, annots), _) ->
      let field_name = name_field field_name annots in
      let java_ty = List.assoc field_name java_tys in
      output_string out (javadoc loc annots "  ");
      fprintf out "  public %s %s;\n" java_ty field_name)
    fields;
  fprintf out "}\n";
  close_out out;
  { env with types = `Class (class_name, java_tys) :: env.types }

(* Translate an `inner' type i.e. a type that occurs within a record or sum *)
and trans_inner env atd_ty =
  match atd_ty with
  | `Name (_, (_, name1, _), _) ->
      (match norm_ty env atd_ty with
         | `Name (_, (_, name2, _), _) ->
             (* It's a primitive type e.g. int *)
             (Atdj_names.to_class_name name2, env)
         | _ ->
             (Atdj_names.to_class_name name1, env)
      )
  | `List (_, sub_atd_ty, _)  ->
      let (ty', env) = trans_inner env sub_atd_ty in
      ("ArrayList<" ^ ty' ^ ">", env)
  | x -> type_not_supported x