%% SPDX-License-Identifier: Apache-2.0
-module(beam_pkg_toml).
-export([decode/1,encode/1]).
-import(beam_pkg_util, [fail/1,get/3,reverse/1,join/2,sort/1,keys/1]).
%% TOML subset parser. No atom creation, evaluation or implicit schema coercion.
decode(B) when byte_size(B) =< 4194304 ->
    try
        document(skip({B, 1, 1}), #{}, [], [])
    catch
        throw:{toml, L, C, M} ->
            fail(["TOML ",
                  integer_to_binary(L),
                  ":",
                  integer_to_binary(C),
                  ": ",
                  M])
    end;
decode(_) ->
    fail("TOML exceeds 4 MiB").
error_at({_, L, C}, M) ->
    throw({toml, L, C, M}).
step({<<$\n,R/binary>>, L, _}) ->
    {R, L + 1, 1};
step({<<_,R/binary>>, L, C}) ->
    {R, L, C + 1}.
peek({<<C,_/binary>>, _, _}) ->
    C;
peek({<<>>, _, _}) ->
    eof.
space(S) ->
    case peek(S) of
        C when C =:= $ ; C =:= $\t; C =:= $\r ->
            space(step(S));
        _ ->
            S
    end.
skip(S) ->
    T = space(S),
    case peek(T) of
        $\n ->
            skip(step(T));
        $# ->
            skip(comment(step(T)));
        _ ->
            T
    end.
comment(S) ->
    case peek(S) of
        eof ->
            S;
        $\n ->
            S;
        _ ->
            comment(step(S))
    end.
expect(S, C) ->
    case peek(S) of
        C ->
            step(S);
        _ ->
            error_at(S, ["expected ", C])
    end.
document(S, M, Path, Tables) ->
    case peek(S) of
        eof ->
            M;
        $[ ->
            {P, T} = keypath(space(step(S))),
            U = expect(space(T), $]),
            case
                beam_pkg_util:member(P, Tables)
                orelse
                beam_pkg_util:member({dotted, P}, Tables)
                orelse
                sealed(P, Tables)
            of
                true ->
                    error_at(S, "duplicate or sealed table");
                false ->
                    ok
            end,
            M1 = table(M, P, S),
            document(line_end(U), M1, P, [P | Tables]);
        _ ->
            {K, T} = keypath(S),
            U = space(expect(space(T), $=)),
            {V, W} = value(U),
            case sealed(Path ++ K, Tables) of
                true ->
                    error_at(S, "duplicate key or sealed table");
                false ->
                    ok
            end,
            document(line_end(W),
                     put(M, Path ++ K, V, S),
                     Path,
                     [{value, Path ++ K} |
                      [ 
                       {dotted, Path ++ Prefix} ||
                           Prefix <- key_prefixes(K)
                      ]]
                     ++
                     Tables)
    end.
line_end(S) ->
    T = space(S),
    case peek(T) of
        eof ->
            T;
        $\n ->
            skip(step(T));
        $# ->
            skip(comment(T));
        _ ->
            error_at(T, "expected end of line")
    end.
keypath(S) ->
    {K, T} = key(S),
    keytail(space(T), [K]).
keytail(S, A) ->
    case peek(S) of
        $. ->
            {K, T} = key(space(step(S))),
            keytail(space(T), [K | A]);
        _ ->
            {reverse(A), S}
    end.
key(S) ->
    case peek(S) of
        $" ->
            string(step(S), $", <<>>);
        $' ->
            string(step(S), $', <<>>);
        _ ->
            bare(S, <<>>)
    end.
bare(S, A) ->
    case peek(S) of
        C
            when
                C >= $a, C =< $z;
                C >= $A, C =< $Z;
                C >= $0, C =< $9;
                C =:= $_;
                C =:= $- ->
            bare(step(S), <<A/binary,C>>);
        _ when A =/= <<>> ->
            {A, S};
        _ ->
            error_at(S, "expected key")
    end.
value(S) ->
    case peek(S) of
        $" ->
            string(step(S), $", <<>>);
        $' ->
            string(step(S), $', <<>>);
        $[ ->
            array(skip(step(S)), []);
        ${ ->
            inline(space(step(S)), #{});
        _ ->
            scalar(S, <<>>)
    end.
string(S, Q, A) ->
    case peek(S) of
        Q ->
            {A, step(S)};
        $\\ when Q =:= $" ->
            {C, T} = escape(step(S)),
            string(T, Q, <<A/binary,C/binary>>);
        C when C =:= eof; C =:= 127; C < 32, C =/= $\t ->
            error_at(S, "unterminated or multiline string");
        _ ->
            {<<C/utf8,R/binary>>, L, N} = S,
            string({R, L, N + 1}, Q, <<A/binary,C/utf8>>)
    end.
escape(S) ->
    case peek(S) of
        $" ->
            {<<$">>, step(S)};
        $\\ ->
            {<<$\\>>, step(S)};
        $n ->
            {<<10>>, step(S)};
        $r ->
            {<<13>>, step(S)};
        $t ->
            {<<9>>, step(S)};
        $b ->
            {<<8>>, step(S)};
        $f ->
            {<<12>>, step(S)};
        $u ->
            hex(step(S), 4, 0);
        $U ->
            hex(step(S), 8, 0);
        _ ->
            error_at(S, "invalid string escape")
    end.
hex(S, 0, N)
    when
        N =< 1114111,
        not (N >= 55296
             andalso
             N =< 57343) ->
    {<<N/utf8>>, S};
hex(S, 0, _) ->
    error_at(S, "invalid Unicode scalar");
hex(S, N, A) ->
    C = peek(S),
    V = case C of
            X when X >= $0, X =< $9 ->
                X - $0;
            X when X >= $a, X =< $f ->
                X - $a + 10;
            X when X >= $A, X =< $F ->
                X - $A + 10;
            _ ->
                error_at(S, "expected hexadecimal digit")
        end,
    hex(step(S), N - 1, A * 16 + V).
array(S, A) ->
    case peek(S) of
        $] ->
            {reverse(A), step(S)};
        _ ->
            {V, T} = value(S),
            U = skip(T),
            case peek(U) of
                $, ->
                    array(skip(step(U)), [V | A]);
                $] ->
                    {reverse([V | A]), step(U)};
                _ ->
                    error_at(U, "expected comma or closing bracket")
            end
    end.
inline(S, M) ->
    case peek(S) of
        $} ->
            {M, step(S)};
        _ ->
            {K, T} = keypath(S),
            {V, U} = value(space(expect(space(T), $=))),
            M1 = put(M, K, V, S),
            W = space(U),
            case peek(W) of
                $, ->
                    Next = space(step(W)),
                    case peek(Next) of
                        $} ->
                            error_at(Next,
                                     "trailing inline-table comma");
                        _ ->
                            inline(Next, M1)
                    end;
                $} ->
                    {M1, step(W)};
                _ ->
                    error_at(W,
                             "expected inline-table comma or closing br"
                             "ace")
            end
    end.
scalar(S, A) ->
    case peek(S) of
        C
            when
                C =:= eof;
                C =:= $ ;
                C =:= $\t;
                C =:= $\r;
                C =:= $\n;
                C =:= $,;
                C =:= $];
                C =:= $};
                C =:= $# ->
            scalar_value(A, S);
        C ->
            scalar(step(S), <<A/binary,C>>)
    end.
scalar_value(<<"true">>, S) ->
    {true, S};
scalar_value(<<"false">>, S) ->
    {false, S};
scalar_value(B, S) ->
    {Sign, D} =
        case B of
            <<$+,R/binary>> ->
                {1, R};
            <<$-,R/binary>> ->
                {-1, R};
            _ ->
                {1, B}
        end,
    case digits(D, false, <<>>) of
        error ->
            error_at(S, "unsupported or invalid TOML value");
        <<>> ->
            error_at(S, "expected value");
        <<$0,Rest/binary>> when Rest =/= <<>> ->
            error_at(S, "leading zero in integer");
        Clean ->
            N = Sign * binary_to_integer(Clean),
            case
                N >= -9223372036854775808
                andalso
                N =< 9223372036854775807
            of
                true ->
                    {N, S};
                false ->
                    error_at(S, "integer out of range")
            end
    end.
digits(<<>>, true, _) ->
    error;
digits(<<>>, false, A) ->
    A;
digits(<<$_,R/binary>>, false, A) when A =/= <<>> ->
    digits(R, true, A);
digits(<<C,R/binary>>, _, A) when C >= $0, C =< $9 ->
    digits(R, false, <<A/binary,C>>);
digits(_, _, _) ->
    error.
table(M, [], _) ->
    M;
table(M, [K | T], S) ->
    case get(K, M, undefined) of
        undefined ->
            M#{K => table(#{}, T, S)};
        V when is_map(V) ->
            M#{K => table(V, T, S)};
        _ ->
            error_at(S, "table conflicts with value")
    end.
put(M, [K], V, S) ->
    case is_map_key(K, M) of
        true ->
            error_at(S, "duplicate key");
        false ->
            M#{K => V}
    end;
put(M, [K | T], V, S) ->
    case get(K, M, #{}) of
        C when is_map(C) ->
            M#{K => put(C, T, V, S)};
        _ ->
            error_at(S, "key conflicts with value")
    end.
encode(M) ->
    Encoded = [
                      [quote(K),
                       " = ",
                       encode_value(map_get(K, M)),
                       "\n"] ||
                          K <- sort(keys(M))
                     ],
    case iolist_size(Encoded) =< 4194304 of
        true -> iolist_to_binary(Encoded);
        false -> fail("TOML exceeds 4 MiB")
    end.
encode_value(M) when is_map(M) ->
    ["{",
     join([ 
           iolist_to_binary([quote(K),
                             " = ",
                             encode_value(map_get(K, M))]) ||
               K <- sort(keys(M))
          ],
          <<", ">>),
     "}"];
encode_value(L) when is_list(L) ->
    ["[",
     join([ 
           iolist_to_binary(encode_value(V)) ||
               V <- L
          ],
          <<", ">>),
     "]"];
encode_value(B) when is_binary(B) ->
    quote(B);
encode_value(true) ->
    "true";
encode_value(false) ->
    "false";
encode_value(N) when is_integer(N) ->
    integer_to_binary(N).
quote(B) ->
    [$",
     [ 
      escaped(C) ||
          <<C/utf8>> <= B
     ],
     $"].
escaped($") ->
    "\\\"";
escaped($\\) ->
    "\\\\";
escaped(10) ->
    "\\n";
escaped(13) ->
    "\\r";
escaped(9) ->
    "\\t";
escaped(C) when C < 32 ->
    fail("unsupported control character");
escaped(C) ->
    <<C/utf8>>.
sealed(P, Tables) ->
    beam_pkg_util:member(true,
                         [ 
                          prefix(K, P) ||
                              {value, K} <- Tables
                         ]).
prefix([], _) ->
    true;
prefix([H | A], [H | B]) ->
    prefix(A, B);
prefix(_, _) ->
    false.
key_prefixes([]) ->
    [];
key_prefixes([_]) ->
    [];
key_prefixes([H | T]) ->
    [[H] |
     [ 
      [H | P] ||
          P <- key_prefixes(T)
     ]].
