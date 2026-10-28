%% SPDX-License-Identifier: Apache-2.0
-module(beam_pkg_archive).
-define(LIMIT, 268435456).
-export([pack/1,unpack/1,extract/2]).
-import(beam_pkg_util,
        [fail/1,sort/1,keys/1,split/2,join/2,reverse/1,safe/1,path/2]).
pack(Files) ->
    case map_size(Files) =< 10000 of
        true -> ok; false -> fail("archive exceeds entry limit")
    end,
    %% Check the complete tar size before allocating its contiguous buffer.
    case packed_size(beam_pkg_util:pairs(Files), 1024) =< ?LIMIT of
        true -> ok;
        false -> fail("archive exceeds size limit")
    end,
    Data =
        iolist_to_binary([ 
                          [header(N, byte_size(map_get(N, Files))),
                           map_get(N, Files),
                           zeros(padding(byte_size(map_get(N, Files))))] ||
                              N <- sort(keys(Files))
                         ]
                         ++
                         [zeros(1024)]),
    case byte_size(Data) =< ?LIMIT of
        true ->
            Compressed = zlib:gzip(Data),
            case byte_size(Compressed) =< ?LIMIT of
                true -> Compressed;
                false -> fail("compressed archive exceeds size limit")
            end;
        false ->
            fail("archive exceeds size limit")
    end.
zeros(N) ->
    <<0:(N * 8)>>.
padding(N) ->
    (512 - N rem 512) rem 512.
field(B, N) when byte_size(B) =< N ->
    <<B/binary,0:((N - byte_size(B)) * 8)>>;
field(_, _) ->
    fail("ustar field exceeds limit").
octal(N, Width) ->
    B = integer_to_binary(N, 8),
    case byte_size(B) < Width of
        true ->
            <<(padzero(Width - byte_size(B) - 1))/binary,B/binary,0>>;
        false ->
            fail("ustar integer exceeds limit")
    end.
padzero(N) ->
    << 
      <<$0>> ||
          _ <- seq(N)
    >>.
seq(0) ->
    [];
seq(N) ->
    [N | seq(N - 1)].
header(Name, Size) ->
    safe(Name),
    {Base, Prefix} = name_fields(Name),
    H = <<(field(Base, 100))/binary,
          (octal(420, 8))/binary,
          (octal(0, 8))/binary,
          (octal(0, 8))/binary,
          (octal(Size, 12))/binary,
          (octal(0, 12))/binary,
          "        ",
          $0,
          0:800,
          "ustar",
          0,
          "00",
          0:512,
          (octal(0, 8))/binary,
          (octal(0, 8))/binary,
          (field(Prefix, 155))/binary,
          0:96>>,
    <<A:148/binary,_:8/binary,B/binary>> = H,
    <<A/binary,(octal(sum(H), 7))/binary,$ ,B/binary>>.
name_fields(N) when byte_size(N) =< 100 ->
    {N, <<>>};
name_fields(N) ->
    Parts = split(N, $/),
    find_split(reverse(Parts), []).
find_split([], _) ->
    fail("artifact path exceeds ustar limits");
find_split([H | T], A) ->
    Base = join([H | A], $/),
    Prefix = join(reverse(T), $/),
    case
        byte_size(Base) =< 100
        andalso
        byte_size(Prefix) =< 155
        andalso
        Prefix =/= <<>>
    of
        true ->
            {Base, Prefix};
        false ->
            find_split(T, [H | A])
    end.
sum(B) ->
    sum(B, 0).
sum(<<>>, N) ->
    N;
sum(<<C,R/binary>>, N) ->
    sum(R, N + C).
%% Bound decompression before validating every entry; extraction is a separate step.
unpack(B) when byte_size(B) =< ?LIMIT ->
    Z = zlib:open(),
    try
        ok = zlib:inflateInit(Z, 31),
        Data = inflate(Z, B, [], 0),
        ok = zlib:inflateEnd(Z),
        parse(Data, #{}, #{}, 0)
    catch
        throw:{package_error, _} = E ->
            throw(E);
        _:_ ->
            fail("invalid gzip/ustar archive")
    after
        zlib:close(Z)
    end;
unpack(_) ->
    fail("compressed archive exceeds limit").
inflate(Z, B, A, N) ->
    case zlib:safeInflate(Z, B) of
        {State, Out} ->
            Size = iolist_size(Out),
            case N + Size =< ?LIMIT of
                false ->
                    fail("expanded archive exceeds limit");
                true ->
                    ok
            end,
            case State of
                finished ->
                    iolist_to_binary(reverse([Out | A]));
                continue ->
                    inflate(Z, <<>>, [Out | A], N + Size)
            end
    end.
parse(<<0:8192,Rest/binary>>, Files, _, _) ->
    case zero(Rest) of
        true ->
            Files;
        false ->
            fail("data after tar terminator")
    end;
parse(<<H:512/binary,Rest/binary>>, Files, Seen, Count)
    when Count < 10000 ->
    <<Name:100/binary,
      _Mode:8/binary,
      _Uid:8/binary,
      _Gid:8/binary,
      SizeB:12/binary,
      _Time:12/binary,
      Check:8/binary,
      Type,
      Link:100/binary,
      Magic:6/binary,
      Version:2/binary,
      _User:32/binary,
      _Group:32/binary,
      _Major:8/binary,
      _Minor:8/binary,
      Prefix:155/binary,
      _:12/binary>> =
        H,
    case {Magic, Version} of
        {<<"ustar",0>>, <<"00">>} ->
            ok;
        _ ->
            fail("unsupported tar format")
    end,
    <<A:148/binary,_:8/binary,C/binary>> = H,
    case number(Check) =:= sum(<<A/binary,"        ",C/binary>>) of
        true ->
            ok;
        false ->
            fail("invalid tar checksum")
    end,
    N0 =
        case cstring(Prefix) of
            <<>> ->
                cstring(Name);
            P ->
                <<P/binary,"/",(cstring(Name))/binary>>
        end,
    N = case Type of
            $5 ->
                strip_slash(N0);
            _ ->
                N0
        end,
    safe(N),
    case is_map_key(N, Seen) of
        true ->
            fail("duplicate archive destination");
        false ->
            ok
    end,
    Size = number(SizeB),
    Pad = padding(Size),
    case
        Size =< ?LIMIT
        andalso
        byte_size(Rest) >= Size + Pad
        andalso
        cstring(Link) =:= <<>>
    of
        true ->
            ok;
        false ->
            fail("invalid tar entry size or link")
    end,
    <<Data:Size/binary,Padding:Pad/binary,Tail/binary>> = Rest,
    case zero(Padding) of
        true ->
            ok;
        false ->
            fail("invalid tar padding")
    end,
    New =
        case Type of
            $0 ->
                Files#{N => Data};
            0 ->
                Files#{N => Data};
            $5 when Size =:= 0 ->
                Files;
            _ ->
                fail("unsupported tar entry type")
        end,
    [ 
     case is_map_key(Parent, Files) of
         true ->
             fail("file used as archive directory");
         false ->
             ok
     end ||
         Parent <- parents(N)
    ],
    case
        Type =/= $5
        andalso
        [ 
         K ||
             K := _ <- Seen,
             beam_pkg_util:member(N, parents(K))
        ]
        =/=
        []
    of
        true ->
            fail("archive file replaces directory");
        false ->
            ok
    end,
    parse(Tail, New, Seen#{N => true}, Count + 1);
parse(_, _, _, _) ->
    fail("truncated archive or entry limit exceeded").
parents(N) ->
    case beam_pkg_util:parent(N) of
        <<"/">> ->
            [];
        P ->
            [P | parents(P)]
    end.
strip_slash(N) ->
    case N of
        <<>> ->
            N;
        _ ->
            case N of
                <<_:(byte_size(N) - 1)/binary,$/>> ->
                    binary_part(N, 0, byte_size(N) - 1);
                _ ->
                    N
            end
    end.
cstring(B) ->
    hd(split(B, 0)).
number(B) ->
    Clean =
        << 
          <<C>> ||
              <<C>> <= B,
              C =/= 0,
              C =/= $ 
        >>,
    case
        Clean =/= <<>>
        andalso
        [ 
         C ||
             <<C>> <= Clean,
             C < $0
             orelse
             C > $7
        ]
        =:=
        []
    of
        true ->
            binary_to_integer(Clean, 8);
        false ->
            fail("invalid tar octal field")
    end.
zero(<<>>) ->
    true;
zero(<<0,R/binary>>) ->
    zero(R);
zero(_) ->
    false.
extract(Files, Root) ->
    [ 
     beam_pkg_util:write(path(Root, N), B) ||
         N := B <- Files
    ],
    ok.

packed_size([], Total) -> Total;
packed_size([{_, Bytes} | Rest], Total) ->
    Size = byte_size(Bytes),
    packed_size(Rest, Total + 512 + Size + padding(Size)).
