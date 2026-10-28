%% SPDX-License-Identifier: Apache-2.0
-module(beam_pkg_manifest).
-export([source/1,
         metadata/1,
         fields/2,
         identity/1,
         string/1,
         strings/1,
         digest/1,
         module/1, nifs/2, native_files/1, format/1, target_key/1]).
-import(beam_pkg_util, [fail/1,get/3,keys/1,member/2]).
source(M) ->
    fields(M,
           [<<"format">>,
            <<"package">>,
            <<"build">>,
            <<"exports">>,
            <<"dependencies">>,
            <<"build-dependencies">>,
            <<"host">>,
            <<"application">>,
            <<"entry">>, <<"scripts">>]),
    common(M),
    beam_pkg_task:scripts(get(<<"scripts">>, M, #{})),
    case get(<<"build-dependencies">>, M, #{}) of
        B when is_map(B), map_size(B) =:= 0 ->
            ok;
        _ ->
            fail("build-dependencies are not supported yet")
    end,
    Build = get(<<"build">>, M, #{}),
    fields(Build,
           [<<"sources">>,
            <<"include-directories">>,
            <<"native">>,
            <<"otp-application">>]),
    case is_map_key(<<"otp-application">>, Build) of
        true ->
            fail("whole OTP application build recipes are not implement"
                 "ed");
        false ->
            ok
    end,
    strings(get(<<"sources">>, Build, [])),
    strings(get(<<"include-directories">>, Build, [])),
    case get(<<"native">>, Build, undefined) of
        undefined ->
            ok;
        N ->
            fields(N, [<<"cmake">>, <<"outputs">>, <<"nifs">>]),
            string(get(<<"cmake">>, N, undefined)),
            Outputs = strings(get(<<"outputs">>, N, undefined)),
            unique(Outputs, "duplicate native source outputs"),
            [native_identifier(P) || P <- Outputs],
            source_nifs(N, Outputs)
    end,
    exports(get(<<"exports">>, M, #{})),
    App = get(<<"application">>, M, #{}),
    fields(App, [<<"file">>, <<"source">>]),
    case is_map_key(<<"source">>, App) of
        true ->
            fail("application templates are not implemented; supply app"
                 "lication.file");
        false ->
            ok
    end,
    case get(<<"file">>, App, undefined) of
        undefined ->
            ok;
        F ->
            string(F),
            suffix(F, <<".app">>)
    end,
    Deps = get(<<"dependencies">>, M, #{}),
    fields_map(Deps),
    [ 
     begin
         package_name(N),
         fields(D,
                [<<"version">>, <<"path">>, <<"archive">>, <<"lock">>]),
         string(get(<<"version">>, D, undefined)),
         case
             {get(<<"path">>, D, undefined),
              get(<<"archive">>, D, undefined),
              get(<<"lock">>, D, undefined)}
         of
             {P, undefined, undefined} when is_binary(P) ->
                 string(P);
             {undefined, A, L} when is_binary(A) ->
                 string(A),
                 case L of
                     undefined ->
                         ok;
                     _ ->
                         string(L)
                 end;
             _ ->
                 fail("dependency needs exactly one path or archive; lo"
                      "ck accompanies archive only")
         end
     end ||
         N := D <- Deps
    ],
    M.
metadata(M) ->
    fields(M,
           [<<"format">>,
            <<"package">>,
            <<"modules">>,
            <<"dependencies">>,
            <<"host">>,
            <<"exports">>,
            <<"application">>,
            <<"entry">>,
            <<"native">>,
            <<"compiler">>, <<"compiler-generation">>]),
    common(M),
    case get(<<"compiler-generation">>,M,undefined) of
        undefined -> fail("archive lacks compiler-generation provenance; rebuild package");
        Generation -> digest(Generation)
    end,
    [ 
     module(N) ||
         N <- strings(get(<<"modules">>, M, undefined))
    ],
    Deps = get(<<"dependencies">>, M, #{}),
    fields_map(Deps),
    [ 
     begin
         package_name(N),
         fields(D, [<<"version">>, <<"sha256">>]),
         string(get(<<"version">>, D, undefined)),
         digest(get(<<"sha256">>, D, undefined))
     end ||
         N := D <- Deps
    ],
    exports(get(<<"exports">>, M, #{})),
    [ 
     begin
         Prefix =
             case K of
                 <<"headers">> ->
                     <<"include/">>;
                 <<"resources">> ->
                     <<"priv/">>;
                 <<"licenses">> ->
                     <<"licenses/">>
             end,
         [ 
          artifact_path(P, Prefix) ||
              P <- Ps
         ]
     end ||
         K := Ps <- get(<<"exports">>, M, #{})
    ],
    sdk(get(<<"compiler">>, M, undefined)),
    case get(<<"application">>, M, #{}) of
        A when map_size(A) =:= 0 ->
            ok;
        A ->
            fields(A, [<<"file">>]),
            artifact_path(get(<<"file">>, A, undefined), <<"ebin/">>)
    end,
    case get(<<"native">>, M, undefined) of
        undefined ->
            ok;
        N ->
            fields_map(N),
            case is_map_key(<<"outputs">>,N) orelse is_map_key(<<"identities">>,N) of
                true -> fail("obsolete native metadata fields; rebuild package with native.artifacts");
                false -> ok
            end,
            fields(N, [<<"sdk">>, <<"recipe">>, <<"nifs">>, <<"artifacts">>]),
            sdk(get(<<"sdk">>, N, undefined)),
            native_artifacts(N),
            nifs(N, get(<<"modules">>, M, [])),
            case get(<<"recipe">>, N, undefined) of
                <<"cmake">> ->
                    ok;
                _ ->
                    fail("unknown native recipe")
            end
    end,
    M.
common(M) ->
    format(M),
    identity(M),
    Host = get(<<"host">>, M, #{}),
    fields(Host, [<<"modules">>, <<"applications">>]),
    [ 
     module(N) ||
         N <- strings(get(<<"modules">>, Host, []))
    ],
    Apps = get(<<"applications">>, Host, #{}),
    fields_map(Apps),
    [ 
     begin
         module(N),
         string(V)
     end ||
         N := V <- Apps
    ],
    Entry = get(<<"entry">>, M, #{}),
    fields(Entry, [<<"module">>]),
    case get(<<"module">>, Entry, undefined) of
        undefined ->
            ok;
        N ->
            module(N)
    end.
exports(E) ->
    fields(E, [<<"headers">>, <<"resources">>, <<"licenses">>]),
    [ 
     strings(V) ||
         _ := V <- E
    ],
    ok.
identity(M) ->
    P = get(<<"package">>, M, #{}),
    fields(P, [<<"name">>, <<"version">>]),
    N = package_name(get(<<"name">>, P, undefined)),
    V = string(get(<<"version">>, P, undefined)),
    {N, V}.
package_name(N) ->
    string(N),
    beam_pkg_util:safe(N),
    case
        [ 
         C ||
             <<C>> <= N,
             not (C >= $a
                  andalso
                  C =< $z
                  orelse
                  C >= $0
                  andalso
                  C =< $9
                  orelse
                  member(C, "/_-."))
        ]
    of
        [] ->
            N;
        _ ->
            fail("invalid package name")
    end.
module(N) ->
    string(N),
    case N of
        <<C,R/binary>> when C >= $a, C =< $z ->
            case
                [ 
                 X ||
                     <<X>> <= R,
                     not (X >= $a
                          andalso
                          X =< $z
                          orelse
                          X >= $A
                          andalso
                          X =< $Z
                          orelse
                          X >= $0
                          andalso
                          X =< $9
                          orelse
                          member(X, "_@"))
                ]
            of
                [] ->
                    N;
                _ ->
                    fail("invalid module name")
            end;
        _ ->
            fail("invalid module name")
    end.
digest(H) when is_binary(H), byte_size(H) =:= 64 ->
    case
        [ 
         C ||
             <<C>> <= H,
             not (C >= $0
                  andalso
                  C =< $9
                  orelse
                  C >= $a
                  andalso
                  C =< $f)
        ]
    of
        [] ->
            H;
        _ ->
            fail("invalid SHA-256")
    end;
digest(_) ->
    fail("invalid SHA-256").
string(B) when is_binary(B), byte_size(B) > 0 ->
    B;
string(_) ->
    fail("expected nonempty string").
strings(L) when is_list(L) ->
    [ 
     string(B) ||
         B <- L
    ];
strings(_) ->
    fail("expected string array").
fields_map(M) when is_map(M) ->
    ok;
fields_map(_) ->
    fail("expected table").
fields(M, Allowed) when is_map(M) ->
    case
        [ 
         K ||
             K <- keys(M),
             not member(K, Allowed)
        ]
    of
        [] ->
            ok;
        Bad ->
            fail(["unknown fields: ",
                  beam_pkg_util:join(beam_pkg_util:sort(Bad), <<", ">>)])
    end;
fields(_, _) ->
    fail("expected table").
suffix(B, S) ->
    N = byte_size(B) - byte_size(S),
    case B of
        <<_:N/binary,S/binary>> when N >= 0 ->
            ok;
        _ ->
            fail(["expected ", S, " file"])
    end.
artifact_path(P, Prefix) ->
    beam_pkg_util:safe(P),
    N = byte_size(Prefix),
    case P of
        <<Prefix:N/binary,_/binary>> ->
            ok;
        _ ->
            fail("artifact outside its declared export directory")
    end.
sdk(M) ->
    fields(M,
           [<<"format">>,
            <<"identity">>,
            <<"build-id">>,
            <<"os">>,
            <<"architecture">>,
            <<"triple">>,
            <<"flavor">>]),
    case get(<<"format">>, M, undefined) of
        1 ->
            ok;
        _ ->
            fail("unsupported SDK metadata")
    end,
    [ 
     string(get(K, M, undefined)) ||
         K <-
             [<<"identity">>,
              <<"os">>,
              <<"architecture">>,
              <<"triple">>,
              <<"flavor">>]
    ],
    digest(get(<<"build-id">>, M, undefined)).

source_nifs(Native, Outputs) ->
    Bindings = get(<<"nifs">>, Native, #{}),
    fields_map(Bindings),
    Paths = [begin
        module(Name),
        native_identifier(P),
        case member(P, Outputs) of
            true -> ok;
            false -> fail("NIF binding needs a declared native output")
        end, P
    end || Name := P <- Bindings],
    unique(Paths, "native library has multiple module bindings").

%% Generated bindings select primary artifacts, never auxiliary files.
nifs(Native, Modules) ->
    Bindings = get(<<"nifs">>, Native, #{}),
    fields_map(Bindings),
    Artifacts = get(<<"artifacts">>, Native, #{}),
    ByPath = #{map_get(<<"path">>, R) => R || _ := R <- Artifacts},
    Paths = [begin
        module(Name), artifact_path(P, <<"priv/">>),
        case member(Name, Modules) of
            true -> ok;
            false -> fail("NIF binding needs a supplied module")
        end,
        case get(P, ByPath, undefined) of
            #{<<"kind">> := <<"shared">>} -> ok;
            #{<<"kind">> := <<"static">>, <<"module">> := Name,
              <<"binding">> := _, <<"header">> := _} -> ok;
            _ -> fail("NIF binding does not match its native artifact")
        end,
        P
    end || Name := P <- Bindings],
    unique(Paths, "native library has multiple module bindings").

native_files(Native) ->
    append_native([map_get(<<"files">>, R) || _ := R <- get(<<"artifacts">>, Native, #{})]).

format(M) ->
    case get(<<"format">>, M, undefined) of
        1 -> ok;
        _ -> fail("unsupported package format; use format 1 sources and regenerate package outputs")
    end.
native_identifier(<<"priv/",_/binary>> = P) -> artifact_path(P, <<"priv/">>);
native_identifier(P) -> native_name(P).
unique(Values, Message) ->
    case length(Values) =:= map_size(#{V => true || V <- Values}) of
        true -> ok; false -> fail(Message)
    end.
native_name(P) ->
    string(P),
    case [C || <<C>> <= P, not ((C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9) orelse C =:= $_ orelse C =:= $-)] of
        [] -> ok; _ -> fail("native outputs must be logical names or paths under priv/")
    end.
target_key(SDK) ->
    sdk(SDK),
    beam_pkg_util:join([get(K,SDK,<<>>) || K <-
        [<<"os">>,<<"architecture">>,<<"flavor">>,<<"build-id">>]],$/).

%% Native link inputs are data, never arbitrary linker flags or CMake code.
native_artifacts(N) ->
    A=get(<<"artifacts">>,N,undefined), fields_map(A),
    SDK=get(<<"build-id">>,map_get(<<"sdk">>,N),undefined),
    Files=append_native([begin
        fields(R,[<<"path">>,<<"kind">>,<<"files">>,<<"dependencies">>,<<"sdk-build-id">>,
                  <<"module">>,<<"header">>,<<"binding">>,<<"language">>]),
        P=get(<<"path">>,R,undefined), artifact_path(P,<<"priv/">>),
        native_identifier(Name),
        Ps=strings(get(<<"files">>,R,undefined)),
        [artifact_path(F,<<"priv/">>) || F<-Ps],
        case member(P,Ps) andalso get(<<"sdk-build-id">>,R,undefined)=:=SDK of
            true -> ok; false -> fail("native artifact SDK/target mismatch or missing primary inventory") end,
        case get(<<"kind">>,R,undefined) of <<"static">> -> ok; <<"shared">> -> ok; _ -> fail("unsupported native kind") end,
        case get(<<"language">>,R,undefined) of <<"C">> -> ok; <<"CXX">> -> ok; _ -> fail("unsupported native language") end,
        Dependencies = strings(get(<<"dependencies">>,R,undefined)),
        unique(Dependencies, "duplicate native dependencies"),
        [case D of
            <<"sdk:runtime">> -> ok;
            <<"system:m">> -> ok;
            <<"system:c++">> -> ok;
            Android when Android=:=<<"system:android">>; Android=:=<<"system:log">>;
                         Android=:=<<"system:dl">>; Android=:=<<"system:c++_shared">> ->
                case map_get(<<"os">>,map_get(<<"sdk">>,N)) of
                    <<"Android">> -> ok; _ -> fail("Android native dependency on another target") end;
            <<"output:",Other/binary>> -> case is_map_key(Other,A) andalso Other=/=Name of
                true -> ok; false -> fail("unresolved native dependency") end;
            _ -> fail("unsupported native dependency")
         end || D <- Dependencies],
        case get(<<"binding">>,R,undefined) of
            undefined -> case is_map_key(<<"header">>,R) orelse is_map_key(<<"module">>,R) of
                true -> fail("incomplete linked-NIF record"); false -> ok end;
            Symbol ->
                c_symbol(Symbol), module(get(<<"module">>,R,undefined)),
                case get(<<"kind">>,R,undefined)=:=<<"static">> andalso member(get(<<"header">>,R,undefined),Ps) of
                    true -> ok; false -> fail("invalid linked-NIF inventory") end
        end,
        Ps
    end || Name:=R<-A]),
    unique(Files, "duplicate native artifact files"),
    native_roots(keys(A), A, #{}), ok.

%% Completed nodes retain their longest suffix, so shared paths cannot hide depth.
native_roots([], _, State) -> State;
native_roots([Name | Rest], A, State) ->
    {_, Next} = native_closure(Name, A, State, 1),
    native_roots(Rest, A, Next).
native_closure(_, _, _, Level) when Level > 128 -> fail("native dependency depth limit");
native_closure(Name, A, State, Level) ->
    case get(Name, State, undefined) of
        visiting -> fail("native dependency cycle");
        Depth when is_integer(Depth) -> {Depth, State};
        undefined ->
            Edges = [Other || <<"output:",Other/binary>> <- map_get(<<"dependencies">>,map_get(Name,A))],
            {Longest, Next} = native_edges(Edges, A, State#{Name => visiting}, Level + 1, 0),
            Depth = Longest + 1,
            case Depth =< 128 of
                true -> {Depth, Next#{Name := Depth}};
                false -> fail("native dependency depth limit")
            end
    end.
native_edges([], _, State, _, Longest) -> {Longest, State};
native_edges([Name | Rest], A, State, Level, Longest) ->
    {Depth, Next} = native_closure(Name, A, State, Level),
    native_edges(Rest, A, Next, Level, max(Longest, Depth)).
append_native([]) -> [];
append_native([H|T]) -> H++append_native(T).
c_symbol(<<C,Rest/binary>>) when C=:=$_; C>=$a,C=<$z; C>=$A,C=<$Z ->
    case [X || <<X>><=Rest,not(X=:=$_ orelse X>=$a andalso X=<$z orelse X>=$A andalso X=<$Z orelse X>=$0 andalso X=<$9)] of
        [] -> ok; _ -> fail("invalid C registration symbol") end;
c_symbol(_) -> fail("invalid C registration symbol").
