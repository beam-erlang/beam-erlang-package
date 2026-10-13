%% SPDX-License-Identifier: Apache-2.0
-module(beam_pkg_build).
-export([run/2, locked/3, validate_files/2, check_providers/1, verify_record/3]).
-import(beam_pkg_util,
        [fail/1,
         get/3,
         path/2,
         parent/1,
         base/1,
         read/1,
         write/2,
         mkdir/1,
         keys/1,
         sort/1,
         member/2,
         text/1]).
%% Publish immutable archives first; replace the root selection only on success.
run(Directory, Context = {_, Prefix, Cwd, _}) ->
    Root = path(Cwd, Directory),
    _ = manifest(Root),
    CMake = beam_pkg_util:tool(<<"cmake">>, Context),
    check_cmake(CMake, Cwd),
    SDK =
        beam_pkg_toml:decode(read(path(Prefix, <<"lib/beam/sdk.toml">>))),
    Work = path(Root, <<"build/beam-pkg">>),
    mkdir(Work),
    Unique = integer_to_binary(erlang:system_time(nanosecond)),
    Stage = path(Work, <<"stage-",Unique/binary>>),
    mkdir(Stage),
    Store = path(Work, <<"artifacts">>),
    mkdir(Store),
    State =
        #{selected => #{},
          visiting => [],
          stage => Stage,
          store => Store,
          root => Root,
          cmake => CMake,
          sdk => SDK,
          prefix => Prefix},
    try
        {Node, Final} = source(Root, State),
        Selected = map_get(selected, Final),
        check_providers(Selected),
        Records = maps_records(Selected),
        Lock =
            #{<<"format">> => 1,
              <<"root">> => map_get(hash, Node),
              <<"artifacts">> => Records},
        Pending = path(Stage, <<"beam.lock">>),
        write(Pending, beam_pkg_toml:encode(Lock)),
        case
            beam_file:rename(Pending,
                             path(Root, <<"beam.lock">>),
                             infinity)
        of
            ok ->
                ok;
            E ->
                fail(["cannot publish lock: ", text(E)])
        end,
        {ok, map_get(archive, Node)}
    after
        cleanup(Stage)
    end.
check_cmake(C, Cwd) ->
    Out = beam_pkg_util:command(C, [<<"--version">>], Cwd),
    case hd(beam_pkg_util:split(Out, 10)) of
        <<"cmake version ",V/binary>> ->
            case beam_pkg_util:split(V, $.) of
                [A, B | _] ->
                    case {binary_to_integer(A), binary_to_integer(B)} of
                        {Major, Minor}
                            when Major > 3; Major =:= 3, Minor >= 25 ->
                            ok;
                        _ ->
                            fail("CMake 3.25 or newer is required")
                    end;
                _ ->
                    fail("invalid CMake version")
            end;
        _ ->
            fail("invalid CMake version")
    end.
manifest(D) ->
    beam_pkg_manifest:source(beam_pkg_toml:decode(read(path(D,
                                                            <<"beam.tom"
                                                              "l">>)))).
source(D, S) ->
    M = manifest(D),
    {Name, Version} = beam_pkg_manifest:identity(M),
    Origin = {source, D},
    case existing(Name, Version, Origin, S) of
        {found, N} ->
            {N, S};
        new ->
            S1 = enter(Name, S),
            Deps = get(<<"dependencies">>, M, #{}),
            {Edges, S2} =
                source_deps(sort(keys(Deps)), Deps, D, S1, #{}),
            SourceStage = path(map_get(stage, S),
                               <<"source-",(integer_to_binary(erlang:unique_integer([positive])))/binary>>),
            mkdir(SourceStage),
            Build = get(<<"build">>, M, #{}),
            Ebin = path(SourceStage, <<"ebin">>),
            mkdir(Ebin),
            Sources = get(<<"sources">>, Build, []),
            Modules =
                [ 
                 source_module(P) ||
                     P <- Sources
                ],
            unique(Modules, "duplicate source module"),
            Includes =
                [ 
                 path(D, P) ||
                     P <- get(<<"include-directories">>, Build, [])
                ]
                ++
                dependency_includes(Edges, S2),
            Compiler = path(map_get(prefix, S), <<"bin/beam">>),
            [ 
             begin
                 Src = path(D, P),
                 _ = read(Src),
                 diagnostic(beam_pkg_util:command(Compiler,
                                                  [<<"--runtime=beam">>,
                                                   <<"compile">>,
                                                   <<"--deterministic">>,
                                                   <<"--no-transforms">>,
                                                   <<"-o">>,
                                                   Ebin]
                                                  ++
                                                  append([ 
                                                          [<<"-I">>, I] ||
                                                              I <-
                                                                  Includes
                                                         ])
                                                  ++
                                                  [<<"--">>, Src],
                                                  D))
             end ||
                 P <- Sources
            ],
            Files0 =
                from_pairs([ 
                            {<<"ebin/",N/binary,".beam">>,
                             read(path(Ebin, <<N/binary,".beam">>))} ||
                                N <- Modules
                           ]),
            {Files1, Exports} =
                exports(get(<<"exports">>, M, #{}), D, Files0),
            {Files2, Application} =
                application(get(<<"application">>, M, #{}), D, Files1),
            {Files3, Native} =
                native(get(<<"native">>, Build, undefined),
                       D, SourceStage, S2, Files2),
            Meta0 =
                #{<<"format">> => 1,
                  <<"package">> => map_get(<<"package">>, M),
                  <<"modules">> => sort(Modules),
                  <<"dependencies">> => Edges,
                  <<"host">> => get(<<"host">>, M, #{}),
                  <<"exports">> => Exports,
                  <<"compiler">> => map_get(sdk, S)},
            Meta1 = optional(<<"application">>, Application, Meta0),
            Meta2 =
                optional(<<"entry">>, get(<<"entry">>, M, #{}), Meta1),
            Meta = optional(<<"native">>, Native, Meta2),
            validate_entry(Meta),
            Files =
                Files3#{<<"package.toml">> => beam_pkg_toml:encode(Meta)},
            beam_pkg_manifest:metadata(Meta),
            validate_files(Meta, Files),
            Archive = beam_pkg_archive:pack(Files),
            Tmp = path(SourceStage, <<"package.bpkg.tar.gz">>),
            write(Tmp, Archive),
            H = beam_pkg_util:hash(Tmp, map_get(cmake, S)),
            Node = publish(H, Meta, Archive, Origin, S2),
            S3 = leave(Name, Node, S2),
            check_providers(map_get(selected, S3)),
            {Node, S3}
    end.
source_module(P) ->
    B = base(P),
    N = byte_size(B) - 4,
    case B of
        <<M:N/binary,".erl">> when N > 0 ->
            beam_pkg_manifest:module(M);
        _ ->
            fail("source inputs must be .erl files")
    end.
source_deps([], _, _, S, E) ->
    {E, S};
source_deps([Name | T], Ds, D, S, E) ->
    Spec = map_get(Name, Ds),
    Version = map_get(<<"version">>, Spec),
    {Node, S1} =
        case get(<<"path">>, Spec, undefined) of
            undefined ->
                A = path(D, map_get(<<"archive">>, Spec)),
                L = case get(<<"lock">>, Spec, undefined) of
                        undefined ->
                            undefined;
                        P ->
                            load_lock(path(D, P))
                    end,
                archive(A, L, undefined, S);
            P ->
                source(path(D, P), S)
        end,
    case beam_pkg_manifest:identity(map_get(meta, Node)) of
        {Name, Version} ->
            ok;
        _ ->
            fail(["dependency identity mismatch: ", Name])
    end,
    source_deps(T, Ds, D, S1,
                E#{Name =>
                       #{<<"version">> => Version,
                         <<"sha256">> => map_get(hash, Node)}}).
existing(Name, Version, Origin, S) ->
    case member(Name, map_get(visiting, S)) of
        true ->
            fail(["dependency cycle: ", Name]);
        false ->
            ok
    end,
    case get(Name, map_get(selected, S), undefined) of
        undefined ->
            new;
        N ->
            case
                {beam_pkg_manifest:identity(map_get(meta, N)),
                 map_get(origin, N)}
            of
                {{Name, Version}, Origin} ->
                    {found, N};
                _ ->
                    fail(["conflicting package selection: ", Name])
            end
    end.
enter(N, S) ->
    case
        length(map_get(visiting, S)) < 128
        andalso
        map_size(map_get(selected, S)) < 1024
    of
        true ->
            S#{visiting := [N | map_get(visiting, S)]};
        false ->
            fail("package graph exceeds depth or node limit")
    end.
leave(Name, Node, S) ->
    S#{visiting :=
           [ 
            N ||
                N <- map_get(visiting, S),
                N =/= Name
           ],
       selected := (map_get(selected, S))#{Name => Node}}.
load_lock(P) ->
    L = beam_pkg_toml:decode(read(P)),
    beam_pkg_manifest:fields(L,
                             [<<"format">>, <<"root">>, <<"artifacts">>]),
    case get(<<"format">>, L, undefined) of
        1 ->
            ok;
        _ ->
            fail("unsupported lock format")
    end,
    beam_pkg_manifest:digest(get(<<"root">>, L, undefined)),
    Records = get(<<"artifacts">>, L, undefined),
    case is_map(Records) of
        true ->
            ok;
        false ->
            fail("invalid lock records")
    end,
    {parent(P), Records}.
%% Hash the captured bytes, not a potentially changing source file.
archive(P, Lock, Expected, S) ->
    Bytes = read(P),
    Input = path(map_get(stage, S), <<"archive-input.bpkg.tar.gz">>),
    write(Input, Bytes),
    H = beam_pkg_util:hash(Input, map_get(cmake, S)),
    case Expected of
        undefined ->
            ok;
        H ->
            ok;
        _ ->
            fail("archive SHA-256 mismatch")
    end,
    Files = beam_pkg_archive:unpack(Bytes),
    Meta =
        beam_pkg_manifest:metadata(beam_pkg_toml:decode(get(<<"package."
                                                              "toml">>,
                                                            Files, <<>>))),
    validate_files(Meta, Files),
    {Name, Version} = beam_pkg_manifest:identity(Meta),
    case existing(Name, Version, {archive, H}, S) of
        {found, N} ->
            {N, S};
        new ->
            S1 = enter(Name, S),
            Edges = get(<<"dependencies">>, Meta, #{}),
            S2 =
                case {map_size(Edges), Lock} of
                    {0, undefined} ->
                        S1;
                    {_, undefined} ->
                        fail("archive with dependencies requires an exp"
                             "licit companion lock");
                    {_, {Base, Records}} ->
                        verify_record(H, Meta, Records),
                        archive_deps(sort(keys(Edges)),
                                     Edges, Base, Records, S1)
                end,
            case get(<<"native">>, Meta, undefined) of
                undefined ->
                    ok;
                N ->
                    case
                        get(<<"sdk">>, N, undefined) =:= map_get(sdk, S)
                    of
                        true ->
                            ok;
                        false ->
                            fail("native archive SDK/target mismatch")
                    end
            end,
            Node = publish(H, Meta, Bytes, {archive, H}, S2),
            {Node, leave(Name, Node, S2)}
    end.
verify_record(H, M, Records) ->
    R = get(H, Records, undefined),
    case R of
        undefined ->
            fail("archive digest missing from companion lock");
        _ ->
            ok
    end,
    beam_pkg_manifest:fields(R,
                             [<<"name">>,
                              <<"version">>,
                              <<"archive">>,
                              <<"dependencies">>]),
    {N, V} = beam_pkg_manifest:identity(M),
    case
        {get(<<"name">>, R, undefined),
         get(<<"version">>, R, undefined),
         get(<<"dependencies">>, R, #{})}
    of
        {N, V, E} ->
            case E =:= get(<<"dependencies">>, M, #{}) of
                true ->
                    ok;
                false ->
                    fail("lock dependency edges disagree with archive")
            end;
        _ ->
            fail("lock identity disagrees with archive")
    end,
    R.
archive_deps([], _, _, _, S) ->
    S;
archive_deps([Name | T], Edges, Base, Records, S) ->
    E = map_get(Name, Edges),
    H = map_get(<<"sha256">>, E),
    R = get(H, Records, undefined),
    case is_map(R) of
        true ->
            ok;
        false ->
            fail("missing dependency in companion lock")
    end,
    P = path(Base,
             beam_pkg_manifest:string(get(<<"archive">>, R, undefined))),
    {N, S1} = archive(P, {Base, Records}, H, S),
    V = map_get(<<"version">>, E),
    case beam_pkg_manifest:identity(map_get(meta, N)) of
        {Name, V} ->
            ok;
        _ ->
            fail("archive dependency identity mismatch")
    end,
    archive_deps(T, Edges, Base, Records, S1).
publish(H, Meta, Bytes, Origin, S) ->
    P = path(map_get(store, S), <<H/binary,".bpkg.tar.gz">>),
    case beam_pkg_util:info(P) of
        {error, #{kind := not_found}} ->
            Tmp = path(map_get(stage, S), <<H/binary,".archive">>),
            write(Tmp, Bytes),
            ok = beam_file:rename(Tmp, P, infinity);
        {ok, #{type := regular}} ->
            case beam_pkg_util:hash(P, map_get(cmake, S)) of
                H ->
                    ok;
                _ ->
                    fail("corrupt existing artifact")
            end;
        _ ->
            fail("invalid artifact destination")
    end,
    #{hash => H, meta => Meta, archive => P, origin => Origin}.
maps_records(Selected) ->
    from_pairs([ 
                begin
                    M = map_get(meta, N),
                    {Name, V} = beam_pkg_manifest:identity(M),
                    H = map_get(hash, N),
                    {H,
                     #{<<"name">> => Name,
                       <<"version">> => V,
                       <<"archive">> =>
                           <<"build/beam-pkg/artifacts/",
                             H/binary,
                             ".bpkg.tar.gz">>,
                       <<"dependencies">> =>
                           get(<<"dependencies">>, M, #{})}}
                end ||
                    _ := N <- Selected
               ]).
dependency_includes(Edges, S) ->
    [ 
     begin
         Node = map_get(Name, map_get(selected, S)),
         Dir =
             path(map_get(stage, S),
                  <<"inputs/",(map_get(hash, Node))/binary>>),
         Files = beam_pkg_archive:unpack(read(map_get(archive, Node))),
         beam_pkg_archive:extract(Files, Dir),
         path(Dir, <<"include">>)
     end ||
         Name <- sort(keys(Edges))
    ].
exports(E, D, F) ->
    export_kinds([{<<"headers">>, <<"include">>},
                  {<<"resources">>, <<"priv">>},
                  {<<"licenses">>, <<"licenses">>}],
                 E, D, F,
                 #{}).
export_kinds([], _, _, F, X) ->
    {F, X};
export_kinds([{K, Dest} | T], E, D, F, X) ->
    Ps = get(K, E, []),
    Pairs =
        [ 
         {<<Dest/binary,"/",(base(P))/binary>>, read(path(D, P))} ||
             P <- Ps
        ],
    F1 = add_files(Pairs, F),
    export_kinds(T, E, D, F1,
                 X#{K =>
                        [ 
                         N ||
                             {N, _} <- Pairs
                        ]}).
application(A, D, F) ->
    case get(<<"file">>, A, undefined) of
        undefined ->
            {F, #{}};
        P ->
            N = <<"ebin/",(base(P))/binary>>,
            {add_files([{N, read(path(D, P))}], F), #{<<"file">> => N}}
    end.
%% CMake owns native compilation; its complete installed inventory is checked.
native(undefined, _, _, _, F) ->
    {F, #{}};
native(N, D, Stage, S, F) ->
    SDK = map_get(sdk, S),
    case get(<<"os">>, SDK, undefined) of
        <<"Linux">> ->
            ok;
        _ ->
            fail("native builds currently require Linux")
    end,
    C = map_get(cmake, S),
    B = path(Stage, <<"native-build">>),
    Install = path(Stage, <<"native-install">>),
    Guard = path(Stage, <<"native-target.cmake">>),
    write(Guard,
          iolist_to_binary(["if(CMAKE_CROSSCOMPILING OR NOT CMAKE_SYSTE"
                            "M_NAME STREQUAL \"",
                            map_get(<<"os">>, SDK),
                            "\" OR NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "
                            "\"",
                            map_get(<<"architecture">>, SDK),
                            "\")\nmessage(FATAL_ERROR \"Native package "
                            "target must match installed SDK\")\nendif("
                            ")\n"])),
    diagnostic(beam_pkg_util:command(C,
                                     [<<"-S">>,
                                      path(D, map_get(<<"cmake">>, N)),
                                      <<"-B">>,
                                      B,
                                      <<"-DCMAKE_BUILD_TYPE=Release">>,
                                      <<"-DBUILD_TESTING=OFF">>,
                                      <<"-DFETCHCONTENT_FULLY_DISCONNEC"
                                        "TED=ON">>,
                                      <<"-DCMAKE_FIND_USE_PACKAGE_REGIS"
                                        "TRY=OFF">>,
                                      <<"-DCMAKE_PROJECT_INCLUDE=",
                                        Guard/binary>>,
                                      <<"-DCMAKE_PREFIX_PATH=",
                                        (map_get(prefix, S))/binary>>,
                                      <<"-DCMAKE_INSTALL_PREFIX=",
                                        Install/binary>>],
                                     D)),
    diagnostic(beam_pkg_util:command(C, [<<"--build">>, B], D)),
    diagnostic(beam_pkg_util:command(C, [<<"--install">>, B], D)),
    Outputs = map_get(<<"outputs">>, N),
    case sort(Outputs) =:= beam_pkg_util:files(Install) of
        true ->
            ok;
        false ->
            fail("native installed inventory differs from declared outp"
                 "uts")
    end,
    {add_files([ 
                {P, read(path(Install, P))} ||
                    P <- Outputs
               ],
               F),
     #{<<"outputs">> => Outputs,
       <<"nifs">> => get(<<"nifs">>, N, #{}),
       <<"recipe">> => <<"cmake">>,
       <<"sdk">> => SDK}}.
validate_files(M, F) ->
    E = get(<<"exports">>, M, #{}),
    Modules = get(<<"modules">>, M, []),
    App = get(<<"application">>, M, #{}),
    Native = get(<<"native">>, M, #{}),
    Names =
        [<<"package.toml">>]
        ++
        [ 
         <<"ebin/",N/binary,".beam">> ||
             N <- Modules
        ]
        ++
        append([ 
                V ||
                    _ := V <- E
               ])
        ++
        get(<<"outputs">>, Native, [])
        ++
        case get(<<"file">>, App, undefined) of
            undefined ->
                [];
            P ->
                [P]
        end,
    unique(Names, "duplicate metadata destination"),
    [ 
     beam_pkg_util:safe(P) ||
         P <- Names
    ],
    case sort(Names) =:= sort(keys(F)) of
        true ->
            ok;
        false ->
            fail("archive files differ from metadata inventory")
    end,
    [ 
     %% Inspect module identity without loading package code into the tool VM.
check_beam(N, map_get(<<"ebin/",N/binary,".beam">>, F)) ||
         N <- Modules
    ],
    beam_pkg_manifest:nifs(Native, Modules),
    validate_entry(M).
check_beam(N, <<"FOR1",Size:32,"BEAM",Chunks/binary>>)
    when Size =:= byte_size(Chunks) + 4 ->
    case atom_chunk(Chunks) of
        N ->
            ok;
        _ ->
            fail("archive bytecode module identity mismatch")
    end;
check_beam(_, _) ->
    fail("invalid BEAM artifact").
atom_chunk(<<Tag:4/binary,Size:32,Rest/binary>>)
    when byte_size(Rest) >= Size ->
    Pad = (4 - Size rem 4) rem 4,
    case Rest of
        <<Chunk:Size/binary,_:Pad/binary,Tail/binary>> ->
            case {Tag, Chunk} of
                {<<"AtU8">>, <<Count:32/signed,Data/binary>>}
                    when Count < 0 ->
                    {Len, Text} = compact_length(Data),
                    case Text of
                        <<Name:Len/binary,_/binary>> ->
                            Name;
                        _ ->
                            fail("truncated atom name")
                    end;
                {<<"AtU8">>, <<Count:32,L,Name:L/binary,_/binary>>}
                    when Count > 0 ->
                    Name;
                {<<"Atom">>, <<Count:32,L,Name:L/binary,_/binary>>}
                    when Count > 0 ->
                    Name;
                _ ->
                    atom_chunk(Tail)
            end;
        _ ->
            fail("truncated BEAM chunk")
    end;
atom_chunk(_) ->
    fail("missing BEAM atom chunk").
validate_entry(M) ->
    case get(<<"module">>, get(<<"entry">>, M, #{}), undefined) of
        undefined ->
            ok;
        N ->
            case member(N, get(<<"modules">>, M, [])) of
                true ->
                    ok;
                false ->
                    fail("entry module is not supplied by root package")
            end
    end.
check_providers(Selected) ->
    Pairs =
        append([ 
                [ 
                 {Mod, Name} ||
                     Mod <- get(<<"modules">>, map_get(meta, N), [])
                ] ||
                    Name := N <- Selected
               ]),
    unique([ 
            M ||
                {M, _} <- Pairs
           ],
           "duplicate module providers"),
    Hosts =
        append([ 
                get(<<"modules">>,
                    get(<<"host">>, map_get(meta, N), #{}),
                    []) ||
                    _ := N <- Selected
               ]),
    case
        [ 
         M ||
             {M, _} <- Pairs,
             member(M, Hosts)
        ]
    of
        [] ->
            ok;
        _ ->
            fail("package module conflicts with declared host provider")
    end.
unique(L, Message) ->
    case
        length(L)
        =:=
        map_size(from_pairs([ 
                             {X, true} ||
                                 X <- L
                            ]))
    of
        true ->
            ok;
        false ->
            fail(Message)
    end.
add_files([], F) ->
    F;
add_files([{P, B} | T], F) ->
    beam_pkg_util:safe(P),
    case is_map_key(P, F) of
        true ->
            fail(["artifact destination collision: ", P]);
        false ->
            add_files(T, F#{P => B})
    end.
optional(_, M, Base) when map_size(M) =:= 0 ->
    Base;
optional(K, V, Base) ->
    Base#{K => V}.
from_pairs(L) ->
    from_pairs(L, #{}).
from_pairs([], M) ->
    M;
from_pairs([{K, V} | T], M) ->
    from_pairs(T, M#{K => V}).
append([]) ->
    [];
append([H | T]) ->
    H ++ append(T).
diagnostic(<<>>) ->
    ok;
diagnostic(B) ->
    beam_output:write(standard_error, B, infinity),
    ok.
compact_length(<<B,R/binary>>) when B band 15 =:= 0 ->
    {B bsr 4, R};
compact_length(<<B,C,R/binary>>) when B band 31 =:= 8 ->
    {B band 224 bsl 3 bor C, R};
compact_length(<<B,R/binary>>) when B band 31 =:= 24, B bsr 5 < 7 ->
    N = B bsr 5 + 2,
    case R of
        <<V:(N * 8),Tail/binary>> ->
            {V, Tail};
        _ ->
            fail("truncated atom length")
    end;
compact_length(_) ->
    fail("unsupported atom length").

%% Cleanup cannot turn a successfully published selection into a reported failure.
cleanup(Stage) ->
    try beam_pkg_util:remove(Stage)
    catch
        Class:Reason ->
            diagnostic(iolist_to_binary(["beam-pkg: staging cleanup failed for ",
                                         Stage, ": ", text({Class, Reason}), "\n"]))
    end.

%% Shared locked-archive graph acquisition for installation. No source recipes.
locked(Root, Stage, Context = {_, Prefix, Cwd, _}) ->
    CMake = beam_pkg_util:tool(<<"cmake">>, Context),
    check_cmake(CMake, Cwd),
    LockPath = path(Root, <<"beam.lock">>),
    {Base, Records} = Lock = load_lock(LockPath),
    L = beam_pkg_toml:decode(read(LockPath)),
    H = map_get(<<"root">>, L),
    R = get(H, Records, #{}),
    Input = beam_pkg_manifest:string(get(<<"archive">>, R, undefined)),
    Store = path(Stage, <<"archives">>), mkdir(Store),
    S = #{selected => #{}, visiting => [], stage => Stage, store => Store,
          cmake => CMake, sdk => beam_pkg_toml:decode(read(path(Prefix, <<"lib/beam/sdk.toml">>)))},
    {Node, Final} = archive(path(Base, Input), Lock, H, S),
    Selected = map_get(selected, Final), check_providers(Selected),
    {Node, Selected}.
