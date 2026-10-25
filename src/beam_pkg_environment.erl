%% SPDX-License-Identifier: Apache-2.0
%% Installed selections have no source or build-tool acquisition policy.
-module(beam_pkg_environment).
-export([install/2, install/3, prepare/1, export_selection/3]).
-import(beam_pkg_util, [path/2, read/1, write/2, mkdir/1, get/3, fail/1, keys/1, sort/1, member/2]).

install(Directory,Context) -> install(Directory,Context,beam_pkg_target:select(Context,undefined)).
install(Directory, Context = {_, _, Cwd, _},Target) ->
    Root = path(Cwd, Directory),
    Base = path(Root, <<".beam">>),
    Generations = path(Base, <<"environments">>),
    mkdir(Generations),
    Id = integer_to_binary(erlang:system_time(nanosecond)),
    Stage = path(Generations, <<"stage-", Id/binary>>),
    Final = path(Generations, Id),
    SDK=map_get(sdk,Target),
    Current=pointer(Base,SDK),
    Pointer = <<Current/binary,"-",Id/binary,".tmp">>,
    mkdir(Stage),
    try
        {RootNode, Nodes} = beam_pkg_build:locked(Root, Stage, Context, Target),
        Installed = [begin
            H = map_get(hash, N),
            Relative = <<"packages/", H/binary>>,
            Files = beam_pkg_archive:unpack(read(map_get(archive, N))),
            Location=path(Stage,Relative),
            beam_pkg_archive:extract(Files, Location),
            Digests=#{P=>beam_pkg_util:hash(path(Location,P),map_get(cmake,Target)) || P:=_<-Files},
            {H,Relative,Digests}
        end || _:=N<-Nodes],
        Packages=#{H=>Relative || {H,Relative,_}<-Installed},
        write(path(Stage,<<"integrity.toml">>),beam_pkg_toml:encode(#{<<"format">>=>1,
            <<"packages">>=>#{H=>Digests || {H,_,Digests}<-Installed}})),
        Environment = #{<<"format">> => 2, <<"root">> => map_get(hash, RootNode),
                        <<"packages">> => Packages, <<"sdk">> => SDK},
        write(path(Stage, <<"environment.toml">>), beam_pkg_toml:encode(Environment)),
        beam_pkg_util:remove(path(Stage, <<"archives">>)),
        beam_pkg_util:remove(path(Stage, <<"archive-input.bpkg.tar.gz">>)),
        rename(Stage, Final),
        write(Pointer, beam_pkg_toml:encode(#{<<"format">> => 2, <<"generation">> => Id})),
        rename(Pointer, Current),
        {ok, Final}
    after
        try beam_pkg_util:remove(Stage) catch _:_ -> ok end,
        try beam_pkg_util:remove(Pointer) catch _:_ -> ok end
    end.

rename(A, B) ->
    case beam_file:rename(A, B, infinity) of
        ok -> ok;
        E -> fail(["cannot publish installed environment: ", beam_pkg_util:text(E)])
    end.

prepare({Context, Directory, HostModules, Purpose}) when Purpose =:= run; Purpose =:= shell ->
    try {ok, selection(Context, Directory, HostModules, Purpose)}
    catch
        throw:{package_error, Message} -> {error, Message};
        Class:Reason -> {error, iolist_to_binary(["invalid installed environment: ", beam_pkg_util:text({Class, Reason})])}
    end.

selection({_, Prefix, Cwd, _}, Directory, HostModules, Purpose) ->
    Base0 = path(path(Cwd, Directory), <<".beam">>),
    SDK=beam_pkg_toml:decode(read(path(Prefix, <<"lib/beam/sdk.toml">>))),
    Current=pointer(Base0,SDK),
    Legacy=path(Base0,<<"current.toml">>),
    Selected=case beam_pkg_util:info(Current) of
        {ok,_} -> Current;
        _ -> case beam_pkg_util:info(Legacy) of
            {ok,_} -> case get(<<"format">>,beam_pkg_toml:decode(read(Legacy)),undefined) of
                1 -> Legacy; _ -> fail("ambiguous old selection; install for this SDK") end;
            _ -> fail("no installed selection; run beam-pkg install first") end
    end,
    Base=directory(Base0),
    Pointer=record(Selected,[<<"format">>,<<"generation">>]),
    Id = beam_pkg_util:safe(get(<<"generation">>, Pointer, undefined)),
    case beam_pkg_util:split(Id, $/) of [_] -> ok; _ -> fail("invalid environment generation") end,
    Generation = directory(path(directory(path(Base, <<"environments">>)), Id)),
    E = record(path(Generation, <<"environment.toml">>), [<<"format">>, <<"root">>, <<"packages">>, <<"sdk">>]),
    Root = beam_pkg_manifest:digest(get(<<"root">>, E, undefined)),
    Locations = get(<<"packages">>, E, #{}),
    case is_map(Locations) andalso map_size(Locations) > 0 andalso map_size(Locations) =< 1024 of
        true -> ok; false -> fail("invalid installed package count")
    end,
    case get(<<"sdk">>,E,SDK) =:= SDK of
        true -> ok; false -> fail("installed environment SDK/target mismatch") end,
    put({?MODULE, budget}, {0, 0}),
    Nodes = #{H => installed(H, Relative, Generation, SDK, HostModules) || H := Relative <- Locations},
    Seen = closure(Root, Nodes, [], #{}),
    case map_size(Seen) =:= map_size(Nodes) of true -> ok; false -> fail("environment contains unselected packages") end,
    beam_pkg_build:check_providers(Nodes),
    Names = [beam_pkg_manifest:identity(map_get(meta, N)) || _ := N <- Nodes],
    case length(Names) =:= map_size(#{Name => true || {Name, _} <- Names}) of
        true -> ok; false -> fail("conflicting installed package identities")
    end,
    M = map_get(meta, map_get(Root, Nodes)),
    Entry = get(<<"module">>, get(<<"entry">>, M, #{}), undefined),
    case {Purpose, Entry} of {run, undefined} -> fail("installed root has no main/1 entry"); _ -> ok end,
    Modules = append([map_get(modules, N) || H <- sort(keys(Nodes)), N <- [map_get(H, Nodes)]]),
    Native = append([map_get(nifs, N) || H <- sort(keys(Nodes)), N <- [map_get(H, Nodes)]]),
    case length(Modules) =< 4096 andalso length(Native) =< 1024 andalso
         sum([byte_size(B) || {_, B, _} <- Modules]) =< 268435456 of
        true -> case Purpose of
            export -> {Root,Nodes,Generation};
            _ -> {case Purpose of shell -> <<"shell">>; run -> Entry end, Modules, Native}
        end;
        false -> fail("project launch inventory exceeds limits")
    end.

installed(H, Relative, Generation, SDK, HostModules) ->
    beam_pkg_manifest:digest(H),
    Expected = <<"packages/", H/binary>>,
    case Relative =:= Expected of true -> ok; false -> fail("invalid installed package location") end,
    P = directory(path(directory(path(Generation, <<"packages">>)), H)),
    Files = installed_files(P, <<>>, 0, #{}),
    M = beam_pkg_manifest:metadata(beam_pkg_toml:decode(get(<<"package.toml">>, Files, <<>>))),
    beam_pkg_build:validate_files(M, Files),
    Host = get(<<"host">>, M, #{}),
    case map_size(get(<<"applications">>, Host, #{})) of
        0 -> ok; _ -> fail("OTP application requirements are unsupported by BEAM project launch")
    end,
    [case member(Name, HostModules) of true -> ok; false -> fail(["missing host module: ", Name]) end
     || Name <- get(<<"modules">>, Host, [])],
    [case member(Name, HostModules) of false -> ok; true -> fail(["package conflicts with host module: ", Name]) end
     || Name <- map_get(<<"modules">>, M)],
    Native = get(<<"native">>, M, #{}),
    case map_size(Native) =:= 0 orelse get(<<"sdk">>, Native, undefined) =:= SDK of
        true -> ok; false -> fail("native installed SDK/target mismatch")
    end,
    #{meta => M,files=>Files,native_meta=>Native,
      modules => [{Name, map_get(<<"ebin/", Name/binary, ".beam">>, Files), path(P, <<"ebin/", Name/binary, ".beam">>)}
                  || Name <- map_get(<<"modules">>, M)],
      nifs => [{Name, path(P, NativePath)} || Name := NativePath <- get(<<"nifs">>, Native, #{})]}.

closure(H, Nodes, Visiting, Seen) ->
    case member(H, Visiting) orelse length(Visiting) >= 128 of
        true -> fail("installed dependency cycle or depth limit"); false -> ok
    end,
    case is_map_key(H, Seen) of
        true -> Seen;
        false ->
            N = case get(H, Nodes, undefined) of undefined -> fail("missing installed dependency"); V -> V end,
            Edges = get(<<"dependencies">>, map_get(meta, N), #{}),
            closure_edges(beam_pkg_util:pairs(Edges), Nodes, [H | Visiting], Seen#{H => true})
    end.
closure_edges([], _, _, Seen) -> Seen;
closure_edges([{Name, Edge} | Rest], Nodes, Visiting, Seen) ->
    H = map_get(<<"sha256">>, Edge),
    N = case get(H, Nodes, undefined) of undefined -> fail("missing installed dependency"); V -> V end,
    Version = map_get(<<"version">>, Edge),
    case beam_pkg_manifest:identity(map_get(meta, N)) of
        {Name, Version} -> ok; _ -> fail("installed dependency identity mismatch")
    end,
    closure_edges(Rest, Nodes, Visiting, closure(H, Nodes, Visiting, Seen)).

record(P, Fields) ->
    M = beam_pkg_toml:decode(read(P)), beam_pkg_manifest:fields(M, Fields),
    beam_pkg_manifest:format(M), M.
directory(P) ->
    case beam_pkg_util:info(P) of
        {ok, #{type := directory}} -> P; _ -> fail(["not an installed directory: ", P])
    end.
append([]) -> [];
append([H | T]) -> H ++ append(T).
sum([]) -> 0;
sum([H | T]) -> H + sum(T).

%% Bound enumeration and reads before retaining bytes in the preparation VM.
installed_files(_, _, Depth, _) when Depth > 64 -> fail("installed directory depth limit");
installed_files(Root, Relative, Depth, Acc) ->
    P = case Relative of <<>> -> Root; _ -> path(Root, Relative) end,
    Entries = case beam_file:list_directory(P, infinity) of
        {ok, L} when length(L) =< 10000 -> L;
        _ -> fail("cannot enumerate bounded installed directory")
    end,
    installed_entries(Entries, Root, Relative, Depth, Acc).
installed_entries([], _, _, _, Acc) -> Acc;
installed_entries([Name | Rest], Root, Relative, Depth, Acc) ->
    R = case Relative of <<>> -> Name; _ -> <<Relative/binary, "/", Name/binary>> end,
    P = path(Root, R),
    {Count, Bytes} = get({?MODULE, budget}),
    case Count < 10000 of true -> ok; false -> fail("installed selection exceeds entry limit") end,
    put({?MODULE, budget}, {Count + 1, Bytes}),
    Next = case beam_pkg_util:info(P) of
        {ok, #{type := directory}} -> installed_files(Root, R, Depth + 1, Acc);
        {ok, #{type := regular, size := Size}} when Bytes + Size =< 268435456 ->
            B = read(P),
            case Bytes + byte_size(B) =< 268435456 of
                true -> ok; false -> fail("installed selection exceeds size limit")
            end,
            put({?MODULE, budget}, {Count + 1, Bytes + byte_size(B)}),
            Acc#{R => B};
        _ -> fail(["not a bounded installed file: ", P])
    end,
    installed_entries(Rest, Root, Relative, Depth, Next).

pointer(Base,SDK) ->
    Build=beam_pkg_manifest:digest(get(<<"build-id">>,SDK,undefined)),
    path(Base,<<"current-",Build/binary,".toml">>).

export_selection({Identity,_,Cwd,Search},Directory,S) ->
    Prefix=map_get(target_prefix,S),
    Core=[atom_to_binary(M,utf8) || M<-erlang:pre_loaded()],
    Host=Core++append([[M || M<-beam_pkg_util:split(read(path(Prefix,<<"lib/beam/",P/binary,"/modules.txt">>)),10),M=/=<<>>]
        || P<-[<<"library">>,<<"boot">>,<<"services">>]]),
    {Root,Nodes,Generation}=selection({Identity,Prefix,Cwd,Search},Directory,Host,export),
    Integrity=record(path(Generation,<<"integrity.toml">>),[<<"format">>,<<"packages">>]),
    Packages=get(<<"packages">>,Integrity,#{}),
    case sort(keys(Packages))=:=sort(keys(Nodes)) of
        true -> ok; false -> fail("installed integrity selection mismatch; reinstall packages") end,
    {Root,#{H=>begin
        Digests=map_get(H,Packages),
        case is_map(Digests) andalso sort(keys(Digests))=:=sort(keys(map_get(files,N))) of
            true -> ok; false -> fail("installed integrity inventory mismatch") end,
        [beam_pkg_manifest:digest(D) || _:=D<-Digests],
        N#{expected_files=>Digests}
    end || H:=N<-Nodes}}.
