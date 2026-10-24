%% SPDX-License-Identifier: Apache-2.0
-module(beam_pkg_manifest).
-export([source/1,
         metadata/1,
         fields/2,
         identity/1,
         string/1,
         strings/1,
         digest/1,
         module/1, nifs/2, format/1, target_key/1]).
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
            nifs(N, undefined),
            [ 
             case P of
                 <<"priv/",_/binary>> ->
                     beam_pkg_util:safe(P);
                 _ ->
                     case get(<<"format">>,M,undefined) of
                         2 -> native_name(P);
                         _ -> fail("format-1 native outputs must be under priv/")
                     end
             end ||
                 P <- strings(get(<<"outputs">>, N, undefined))
            ]
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
            <<"compiler">>]),
    common(M),
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
            fields(N, [<<"outputs">>, <<"sdk">>, <<"recipe">>, <<"nifs">>, <<"identities">>]),
            [ 
             artifact_path(P, <<"priv/">>) ||
                 P <- strings(get(<<"outputs">>, N, undefined))
            ],
            sdk(get(<<"sdk">>, N, undefined)),
            Identities=get(<<"identities">>,N,#{}),
            fields_map(Identities),
            [begin
                native_name(Name), artifact_path(P,<<"priv/">>),
                case member(P,get(<<"outputs">>,N,[])) of
                    true -> ok; false -> fail("native identity has no declared output") end
             end || Name := P <- Identities],
            case map_size(Identities)=:=map_size(#{P => true || _ := P <- Identities}) of
                true -> ok; false -> fail("duplicate native identity paths") end,
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

%% One explicit bytecode provider per native library; no filename inference.
nifs(Native, Modules) ->
    Bindings = get(<<"nifs">>, Native, #{}),
    fields_map(Bindings),
    Outputs = strings(get(<<"outputs">>, Native, [])),
    Paths = [begin
        module(Name),
        case {Modules,P} of
            {undefined,<<"priv/",_/binary>>} -> artifact_path(P,<<"priv/">>);
            {undefined,_} -> native_name(P);
            _ -> artifact_path(P,<<"priv/">>)
        end,
        case member(P, Outputs) andalso (Modules =:= undefined orelse member(Name, Modules)) of
            true -> ok;
            false -> fail("NIF binding needs a supplied module and declared native output")
        end, P
    end || Name := P <- Bindings],
    case length(Paths) =:= map_size(#{P => true || P <- Paths}) of
        true -> ok;
        false -> fail("native library has multiple module bindings")
    end.

%% Version one has concrete native paths; version two can name CMake outputs.
format(M) ->
    case get(<<"format">>, M, undefined) of
        V when V =:= 1; V =:= 2 -> ok;
        _ -> fail("unsupported package format; rebuild with format 2")
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
