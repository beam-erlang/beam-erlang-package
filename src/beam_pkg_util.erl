%% SPDX-License-Identifier: Apache-2.0
-module(beam_pkg_util).
-export([fail/1,
         get/3,
         pairs/1,
         keys/1,
         sort/1,
         reverse/1,
         member/2,
         split/2,
         join/2,
         path/2,
         parent/1,
         base/1,
         read/1,
         write/2,
         mkdir/1,
         info/1,
         files/1,
         remove/1,
         command/3,
         hash/2,
         tool/2,
         text/1,
         safe/1]).
fail(Text) ->
    throw({package_error, iolist_to_binary(Text)}).
get(K, M, D) ->
    case M of
        #{K := V} ->
            V;
        _ ->
            D
    end.
pairs(M) ->
    [ 
     {K, V} ||
         K := V <- M
    ].
keys(M) ->
    [ 
     K ||
         K := _ <- M
    ].
reverse(L) ->
    rev(L, []).
rev([], A) ->
    A;
rev([H | T], A) ->
    rev(T, [H | A]).
sort([]) ->
    [];
sort([X]) ->
    [X];
sort(L) ->
    {A, B} = halves(L, [], []),
    merge(sort(A), sort(B)).
halves([], A, B) ->
    {A, B};
halves([X], A, B) ->
    {[X | A], B};
halves([X, Y | T], A, B) ->
    halves(T, [X | A], [Y | B]).
merge([], B) ->
    B;
merge(A, []) ->
    A;
merge([X | A], [Y | B]) when X =< Y ->
    [X | merge(A, [Y | B])];
merge(A, [Y | B]) ->
    [Y | merge(A, B)].
member(_, []) ->
    false;
member(X, [X | _]) ->
    true;
member(X, [_ | T]) ->
    member(X, T).
split(B, C) ->
    split(B, C, <<>>, []).
split(<<>>, _, A, R) ->
    reverse([A | R]);
split(<<C,R/binary>>, C, A, L) ->
    split(R, C, <<>>, [A | L]);
split(<<X,R/binary>>, C, A, L) ->
    split(R, C, <<A/binary,X>>, L).
join([], _) ->
    <<>>;
join([H | T], S) ->
    iolist_to_binary([H,
                      [ 
                       [S, X] ||
                           X <- T
                      ]]).
path(Base, P) ->
    case erlang:system_info(os_type) of
        {win32, _} -> windows_path(slashes(Base), slashes(P));
        _ -> case P of
            <<"/",_/binary>> -> normalize(P);
            _ -> normalize(<<Base/binary,"/",P/binary>>)
        end
    end.
slashes(P) -> << <<(case C of $\\ -> $/; _ -> C end)>> || <<C>> <= P >>.
windows_path(_, <<D,$:,$/,Rest/binary>>) when D >= $A, D =< $Z ->
    windows_path(<<>>, <<(D+32),$:,$/,Rest/binary>>);
windows_path(_, <<D,$:,$/,Rest/binary>>) when D >= $a, D =< $z ->
    <<D,$:,$/,(join(reverse(parts(split(Rest,$/),[])),$/))/binary>>;
windows_path(_, <<"//",Rest/binary>>) ->
    case split(Rest,$/) of
        [Server,Share|Tail] when Server =/= <<>>, Share =/= <<>> ->
            <<"//",Server/binary,"/",Share/binary,"/",(join(reverse(parts(Tail,[])),$/))/binary>>;
        _ -> fail("Windows UNC paths require a server and share")
    end;
windows_path(_, <<"/",_/binary>>) -> fail("Windows paths require an absolute drive or UNC share");
windows_path(<<>>, _) -> fail("Windows paths require an absolute drive or UNC share");
windows_path(Base, P) -> windows_path(<<>>, <<Base/binary,"/",P/binary>>).
normalize(P) ->
    <<"/",(join(reverse(parts(split(P, $/), [])), $/))/binary>>.
parts([], A) ->
    A;
parts([<<>> | T], A) ->
    parts(T, A);
parts([<<".">> | T], A) ->
    parts(T, A);
parts([<<"..">> | T], [_ | A]) ->
    parts(T, A);
parts([<<"..">> | T], []) ->
    parts(T, []);
parts([H | T], A) ->
    parts(T, [H | A]).
base(P) ->
    hd(reverse(split(P, $/))).
parent(<<D,$:,$/>>) -> <<D,$:,$/>>;
parent(P) ->
    case reverse(split(P, $/)) of
        [_ | T] ->
            case join(reverse(T), $/) of
                <<>> ->
                    <<"/">>;
                <<D,$:>> -> <<D,$:,$/>>;
                B ->
                    B
            end
    end.
safe(P) when is_binary(P), byte_size(P) > 0 ->
    case P of
        <<"/",_/binary>> ->
            fail("absolute artifact path");
        _ ->
            ok
    end,
    case
        [ 
         X ||
             X <- split(P, $/),
             X =:= <<>>
             orelse
             X =:= <<".">>
             orelse
             X =:= <<"..">>
        ]
    of
        [] ->
            ok;
        _ ->
            fail("invalid artifact path")
    end,
    case
        [ 
         C ||
             <<C/utf8>> <= P,
             C < 32
             orelse
             C =:= 127
             orelse
             C =:= $\\
        ]
    of
        [] ->
            ok;
        _ ->
            fail("invalid path character")
    end,
    P;
safe(_) ->
    fail("expected nonempty relative path").
info(P) ->
    beam_file:info(P, infinity).
read(P) ->
    case info(P) of
        {ok, #{type := regular, size := S}} when S =< 268435456 ->
            case beam_file:read_file(P, infinity) of
                {ok, B} ->
                    B;
                E ->
                    fail(["cannot read ", P, ": ", text(E)])
            end;
        E ->
            fail(["not a bounded regular file: ", P, ": ", text(E)])
    end.
write(P, B) ->
    mkdir(parent(P)),
    case beam_file:write_file(P, B, infinity) of
        ok ->
            ok;
        E ->
            fail(["cannot write ", P, ": ", text(E)])
    end.
mkdir(<<"/">>) ->
    ok;
mkdir(P) ->
    case info(P) of
        {ok, #{type := directory}} ->
            ok;
        {error, #{kind := not_found}} ->
            mkdir(parent(P)),
            case beam_file:make_directory(P, infinity) of
                ok ->
                    ok;
                {error, #{reason := eexist}} ->
                    mkdir(P);
                E ->
                    fail(text(E))
            end;
        E ->
            fail(["not a directory: ", P, ": ", text(E)])
    end.
files(P) ->
    case beam_file:list_directory(P, infinity) of
        {ok, L} ->
            sort(files(P, L));
        E ->
            fail(text(E))
    end.
files(_, []) ->
    [];
files(P, [N | T]) ->
    F = path(P, N),
    Next =
        case info(F) of
            {ok, #{type := regular}} ->
                [N];
            {ok, #{type := directory}} ->
                [ 
                 <<N/binary,"/",X/binary>> ||
                     X <- files(F)
                ];
            _ ->
                fail(["unsupported filesystem entry: ", F])
        end,
    Next ++ files(P, T).
remove(P) ->
    case info(P) of
        {error, #{kind := not_found}} ->
            ok;
        {ok, #{type := directory}} ->
            {ok, L} = beam_file:list_directory(P, infinity),
            [ 
             remove(path(P, N)) ||
                 N <- L
            ],
            ok = beam_file:remove_directory(P, infinity);
        {ok, _} ->
            ok = beam_file:remove_file(P, infinity);
        E ->
            fail(text(E))
    end.
text(T) ->
    beam_format:term(T, #{depth => 12, bytes => 4096}).
tool(Name, {_, _, Cwd, Search}) ->
    Windows = case erlang:system_info(os_type) of {win32,_} -> true; _ -> false end,
    Separator = case Windows of true -> $;; false -> $: end,
    Executable = case Windows andalso not has_extension(Name) of true -> <<Name/binary,".exe">>; false -> Name end,
    find_tool(Executable,
              [ 
               path(Cwd, D) ||
                   D <- split(Search, Separator)
              ]).
has_extension(Name) -> length(split(base(slashes(Name)), $.)) > 1.
find_tool(N, []) ->
    fail(["required executable not found: ", N]);
find_tool(N, [D | T]) ->
    P = path(D, N),
    case info(P) of
        {ok, #{type := regular}} ->
            P;
        {ok, #{type := symlink}} ->
            P;
        _ ->
            find_tool(N, T)
    end.
%% Arguments go directly to the executable, never through a shell.
command(Exe, Args, Cwd) ->
    Port =
        try
            open_port({spawn_executable, unicode_list(Exe)},
                      [binary, exit_status, use_stdio, stderr_to_stdout,
                       {cd, unicode_list(Cwd)},
                       {args,
                        [ 
                         unicode_list(A) ||
                             A <- Args
                        ]}])
        catch
            _:R ->
                fail(["cannot execute ", Exe, ": ", text(R)])
        end,
    collect(Port, [], 0, erlang:monotonic_time(millisecond) + 600000).
unicode_list(B) ->
    [ 
     C ||
         <<C/utf8>> <= B
    ].
collect(P, A, N, End) ->
    Wait = max(0, End - erlang:monotonic_time(millisecond)),
    receive
        {P, {data, B}} when N + byte_size(B) =< 16777216 ->
            collect(P, [B | A], N + byte_size(B), End);
        {P, {data, _}} ->
            port_close(P),
            fail("tool output exceeds limit");
        {P, {exit_status, 0}} ->
            iolist_to_binary(reverse(A));
        {P, {exit_status, S}} ->
            fail(["tool failed (",
                  integer_to_binary(S),
                  "): ",
                  reverse(A)])
    after
        Wait ->
            port_close(P),
            fail("tool timed out")
    end.
hash(P, C) ->
    Out = command(C, [<<"-E">>, <<"sha256sum">>, P], parent(P)),
    case Out of
        <<H:64/binary,"  ",_/binary>> ->
            case
                [ 
                 X ||
                     <<X>> <= H,
                     not (X >= $0
                          andalso
                          X =< $9
                          orelse
                          X >= $a
                          andalso
                          X =< $f)
                ]
            of
                [] ->
                    H;
                _ ->
                    fail("invalid SHA-256 output")
            end;
        _ ->
            fail("invalid SHA-256 output")
    end.
