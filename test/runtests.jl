using Dates
using Distributed
using JSON
using Test

using Discord
using Discord:
    EMPTY,
    Bucket,
    Handler,
    Response,
    Limiter,Snowflake,
    datetime,
    get_channel_message,
    handlers,
    increment,
    insert_or_update!,
    isexpired,
    islimited,
    parse_endpoint,
    process_id,
    readjson,
    snowflake,
    snowflake2datetime,
    worker_id,
    writejson,
    @boilerplate,
    @dict,
    @lower,
    @merge

# A test case which covers most possible field types.
@eval Discord struct Foo
    a::String
    b::DateTime
    c::Snowflake
    d::Vector{String}
    e::Union{Int, Nothing}
    f::Union{Int, Missing}
    g::Union{Vector{String}, Nothing, Missing}
    h::Union{Foo, Missing}
    abcdefghij::Union{Int, Missing}  # 10 characters.
end
@eval Discord @boilerplate Foo :dict :docs :lower :merge

# A simple struct with merge.
@eval Discord struct Bar
    id::Int
    x::Int
    y::Union{Int, Missing}
end
@eval Discord @boilerplate Bar :merge

using Discord: Foo, Bar

# A module with event handlers.
module Handlers

export a, b

using Discord

a(::Client, ::AbstractEvent) = nothing
a(::Client, ::TypingStart) = nothing
b(::Client, ::WebhookUpdate) = nothing
c(::Client, ::WebhookUpdate) = nothing

end

@testset "Discord.jl" begin
    c = Client("token")

    @testset "Client" begin
        @testset "Token" begin
            # Tokens should always be prepended by "Bot ".
            c = Client("token")
            @test c.token == "Bot token"
            # Unless it's already there.
            c = Client("Bot token")
            @test c.token == "Bot token"
        end

        @testset "Utils" begin
            # We haven't connected to the gateway yet.
            @test me(c) === nothing

            disable_cache!(c)
            @test !c.use_cache
            enable_cache!(c) do
                @test c.use_cache
            end
            @test !c.use_cache
            enable_cache!(c)
            @test c.use_cache
            disable_cache!(c) do
                @test !c.use_cache
            end
            @test c.use_cache

            # TTL choice should propagate to the State.
            set_ttl!(c, Minute(1))
            @test c.ttl == Minute(1)
            @test c.state.ttl == Minute(1)
        end
    end

    @testset "Parsing" begin
        @testset "tryparse" begin
            @test tryparse(c, Int, 123) == (123, nothing)
            @test tryparse(c, Vector{UInt16}, Int[1, 2, 3]) == (UInt16[1, 2, 3], nothing)
            val, e = @test_logs (:error, r"MethodError") tryparse(c, Int, Dict())
            @test val === nothing
            @test e isa MethodError
            @test first(c.state.errors) == Dict()
        end

        @testset "Snowflake" begin
            # Snowflakes usually come in as strings.
            s = snowflake(string(typemax(UInt64)))
            @test isa(s, Snowflake)
            # Snowflake === UInt64.
            @test s == typemax(UInt64)

            # https://discordapp.com/developers/docs/reference#snowflakes-snowflake-id-format-structure-left-to-right
            s = Snowflake(0x06ecefa78e42000c)
            @test snowflake2datetime(s) == DateTime(2018, 10, 9, 1, 55, 31, 1)
            @test worker_id(s) == 0x01
            @test process_id(s) == 0x00
            @test increment(s) == 0x0c
        end

        @testset "DateTime" begin
            # Discord sends dates in some weird, inconsistent ways.
            d = datetime("2018-10-08T05:20:22.782643+00:00")
            @test d == DateTime(2018, 10, 8, 5, 20, 22, 782)
            d = datetime("2018-10-08T05:20:22.782Z")
            @test d == DateTime(2018, 10, 8, 5, 20, 22, 782)

            # But sometimes they also send nice millisecond Unix timestamps.
            d = datetime(1541288588543)
            @test d == DateTime(2018, 11, 3, 23, 43, 08, 543)
        end
    end

    @testset "[read|write]json" begin
        io = IOBuffer()
        val, e = readjson(io)
        @test val === nothing
        @test e == EMPTY

        io = IOBuffer("{bad]")
        val, e = readjson(io)
        @test val === nothing
        @test e !== nothing

        io = IOBuffer("[1,2,3]")
        val, e = readjson(io)
        @test val == [1, 2, 3]
        @test e === nothing

        io = IOBuffer()
        @test writejson(io, @__MODULE__) !== nothing

        io = IOBuffer()
        @test writejson(io, [1, 2, 3]) === nothing
        @test String(take!(io)) == "[1,2,3]"

        io = IOBuffer()
        d = Dict("foo" => 0, "bar" => [1, 2, 3])
        @test writejson(io, d) === nothing
        @test JSON.parse(String(take!(io))) == d
    end

    @testset "Helpers" begin
        @testset "mention" begin
            ch = DiscordChannel(Dict("id" => "255", "type" => 0, "guild_id" => "1"))
            @test mention(ch) == "<#255>"

            r = Role(0xff, "", 0, true, 0, 0, false, false)
            @test mention(r) == "<@&255>"

            u = User(Dict{String, Any}("id" => "255", "username" => "foo"))
            @test mention(u) == "<@255>"

            m = Member(u, "foo", [], now(), true, true)
            @test mention(m) == "<@!255>"
            m = Member(u, nothing, [], now(), true, true)
            @test mention(m) == mention(u)
            m = Member(u, missing, [], now(), true, true)
            @test mention(m) == mention(u)

            msg = Message(Dict(
                "id" => "1",
                "channel_id" => "1",
                "content" => "<@255> <@!255>",
                "mentions" => [JSON.lower(u)],
            ))
            @test replace_mentions(msg) == "@foo @foo"
        end
    end

    @testset "High-level REST API" begin
        @testset "Direct endpoint wrapper" begin
            # Direct endpoint wrappers should return a Future.
            f = get_channel_message(c, 123, 456)
            @test f isa Future
            # Since we don't have a valid token, we shouldn't get anything.
            @test fetchval(f) === nothing
            r = fetch(f)
            # But the type should still be sound.
            @test r isa Response{Message}
            @test !r.ok
            @test r.val === nothing
            @test r.http_response !== nothing
            @test r.exception === nothing
        end

        @testset "CRUD" begin
            # This API should behave just like the direct endpoint wrappers.
            f = create(c, Guild; name="foo")
            @test f isa Future
            r = fetch(f)
            @test r isa Response{Guild}
            @test r.val === nothing
            @test !r.ok
            @test r.http_response !== nothing
            @test r.exception === nothing
        end

        @testset "Simultaneous requests" begin
            # We should be able to make a bunch of requests without deadlocking.
            fs = map(i -> retrieve(c, Guild, i), 1:10)
            @test all(f -> f isa Future, fs)
            rs = fetch.(fs)
            @test all(r -> r isa Response{Guild}, rs)
        end
    end

    @testset "Rate limiting" begin
        @testset "Buckets" begin
            l = Limiter()

            # We start with no buckets.
            @test isempty(l.buckets)
            # But when we need one, it gets created for us.
            b = Bucket(l, :GET, "/foo")
            @test collect(keys(l.buckets)) == ["/foo"]
            # An unused bucket isn't limited.
            @test !islimited(l, b)

            # We can treat buckets like a lock.
            lock(b)
            @test b.sem.curr_cnt == 1
            unlock(b)
            @test b.sem.curr_cnt == 0

            # As long as the bucket isn't empty, we aren't limited.
            b.remaining = 1
            # Even if the reset hasn't yet passed.
            b.reset = now(UTC) + Second(1)
            @test !islimited(l, b)

            # But if the bucket is empty, then we're limited.
            b.remaining = 0
            @test islimited(l, b)

            # Once we wait, the bucket is reset.
            wait(l, b)
            b = Bucket(l, :GET, "/foo")
            @test !islimited(l, b)
            @test b.remaining === nothing
            @test b.reset === nothing
        end

        @testset "parse_endpoint" begin
            # The variable parameter doesn't matter.
            @test parse_endpoint("/users/1", :GET) == "/users"

            # Unless it's one of these three.
            @test parse_endpoint("/channels/1", :GET) == "/channels/1"
            @test parse_endpoint("/guilds/1", :GET) == "/guilds/1"
            @test parse_endpoint("/webhooks/1", :GET) == "/webhooks/1"

            # Without a numeric parameter at the end, we get the whole endpoint.
            @test parse_endpoint("/users/@me/channels", :GET) == "/users/@me/channels"

            # Special case 1: Deleting messages.
            @test ==(
                parse_endpoint("/channels/1/messages/1", :DELETE),
                "/channels/1/messages DELETE",
            )
            @test parse_endpoint("/channels/1/messages/1", :GET) == "/channels/1/messages"

            # Special case 2: Invites.
            @test parse_endpoint("/invites/abcdef", :GET) == "/invites"
        end
    end

    @testset "Boilerplate" begin
        local f
        d = Dict(
            "a" => "foo",
            "b" => "2018-10-08T05:20:22.782Z",
            "c" => "1234567890",
            "d" => ["a", "b", "c"],
            "e" => 1,
            "f" => 2,
            "g" => ["a", "b", "c"],
        )
        d["h"] = copy(d)

        @testset "@dict" begin
            f = Foo(d)
            @test f.a == "foo"
            @test f.b == DateTime(2018, 10, 8, 5, 20, 22, 782)
            @test f.c == 1234567890
            @test f.d == ["a", "b", "c"]
            @test f.e == 1
            @test f.f == 2
            @test f.g == ["a", "b", "c"]
            @test f.h isa Foo && f.h.a == "foo"

            # Set e to nothing, f and g to missing.
            d["e"] = nothing
            delete!(d, "f")
            delete!(d, "g")
            f = Foo(d)
            @test f.e === nothing
            @test ismissing(f.f)
            @test ismissing(f.g)

            # Union{T, Nothing, Missing} works too.
            d["g"] = nothing
            f = Foo(d)
            @test f.g === nothing
        end

        @testset "@docs" begin
            # Variable names get padded to the longest one.
            @test occursin("$(rpad("a", 10)) :: String", string(@doc Foo))
        end

        @testset "@lower" begin
            d["b"] = d["h"]["b"] = round(Int, datetime2unix(f.b))
            d["c"] = d["h"]["c"] = snowflake(f.c)
            d = JSON.lower(f)
            # The result is always a Dict{String, Any}.
            @test d isa Dict{String, Any}
            @test d == Dict(
                "a" => "foo",
                "b" => d["b"],
                "c" => d["c"],
                "d" => ["a", "b", "c"],
                "e" => nothing,
                "g" => nothing,
                "h" => d["h"],
            )
        end

        @testset "@merge" begin
            # Anything except missing values should be taken from f2.
            f2 = Foo("bar", f.b, f.c, f.d, f.e, f.f, f.g, missing, missing)
            f3 = merge(f, f2)
            @test f3.a == f2.a
            @test f3.h == f.h
        end
    end

    @testset "Handlers" begin
        c = Client("token")
        f(c, e) = nothing
        g(c, e) = nothing
        badh(c, e::String) = nothing
        badc(c, e::AbstractEvent) = nothing

        @testset "Adding/deleting regular handlers" begin
            # Deleting handlers without a tag clears all handlers for that type.
            delete_handler!(c, MessageCreate)
            @test !haskey(c.handlers, MessageCreate)

            # Adding handlers without a tag means we can have duplicates.
            add_handler!(c, MessageCreate, f)
            add_handler!(c, MessageCreate, f)
            @test length(get(c.handlers, MessageCreate, [])) == 2
            delete_handler!(c, MessageCreate)

            # Using tags prevents duplicates.
            add_handler!(c, MessageCreate, f; tag=:f)
            add_handler!(c, MessageCreate, f; tag=:f)
            @test length(get(c.handlers, MessageCreate, [])) == 1

            # With tags, we can delete specific handlers.
            add_handler!(c, MessageCreate, g; tag=:g)
            @test length(get(c.handlers, MessageCreate, [])) == 2
            delete_handler!(c, MessageCreate, :g)
            @test length(get(c.handlers, MessageCreate, [])) == 1
            @test first(collect(c.handlers[MessageCreate])).f == f

            # We can also add handlers from a module.
            add_handler!(c, Handlers)
            @test length(get(c.handlers, AbstractEvent, [])) == 1
            @test length(get(c.handlers, TypingStart, [])) == 1
            # Only exported functions are considered.
            @test length(get(c.handlers, WebhookUpdate, [])) == 1
            @test first(collect(c.handlers[WebhookUpdate])).f == Handlers.b

            # Adding a module handler with a tag and/or expiry propogates to all handlers.
            empty!(c.handlers)
            add_handler!(c, Handlers; tag=:h, expiry=Millisecond(50))
            @test all(hs -> all(h -> h.tag === :h, hs), values(c.handlers))
            sleep(Millisecond(50))
            @test all(hs -> all(isexpired, hs), values(c.handlers))

            # We can't add a handler without a valid method.
            @test_throws ArgumentError add_handler!(c, MessageCreate, badh)

            # We can't add a handler that's already expired.
            @test_throws ArgumentError add_handler!(c, Ready, f; expiry=0)
            @test_throws ArgumentError add_handler!(c, Ready, f; expiry=Day(-1))
        end

        @testset "Commands" begin
            delete_handler!(c, MessageCreate)
            h(c, m) = nothing

            # Adding commands adds to the MessageCreate handlers.
            add_command!(c, "!test", h)
            @test length(get(c.handlers, MessageCreate, [])) == 1
            # But the handler function is modified.
            @test first(collect(c.handlers[MessageCreate])).f != f

            # We can't add a command without a valid method.
            @test_throws Exception add_command!(c, "!test", badc)

            # We can't add a command that's already expired.
            @test_throws ArgumentError add_command!(c, "!test", h; expiry=0)
            @test_throws ArgumentError add_handler!(c, Ready, f; expiry=Day(-1))
        end

        @testset "Handler expiry" begin
            empty!(c.handlers[MessageCreate])

            # By default, handlers don't expire.
            add_handler!(c, MessageCreate, f)
            @test !isexpired(first(c.handlers[MessageCreate]))

            add_handler!(c, MessageCreate, f; expiry=Millisecond(100))
            @test count(isexpired, c.handlers[MessageCreate]) == 0
            sleep(Millisecond(100))
            @test count(isexpired, c.handlers[MessageCreate]) == 1

            # Counting handlers expire when they reach 0 (and never expire when negative).
            @test !isexpired(Handler(f, gensym(), -11))
            @test !isexpired(Handler(f, gensym(), 1))
            @test isexpired(Handler(f, gensym(), 0))

            # Timed handlers expire when their expiry time is reached.
            @test !isexpired(Handler(f, gensym(), now() + Day(1)))
            @test isexpired(Handler(f, gensym(), now() - Day(1)))
        end

        @testset "Handler collection" begin
            # No handlers means no handlers.
            empty!(c.handlers)
            @test isempty(handlers(c, MessageCreate))
            @test isempty(handlers(c, AbstractEvent))
            @test isempty(handlers(c, FallbackEvent))

            # Both the specific and catch-all handler should match.
            add_handler!(c, MessageCreate, f)
            add_handler!(c, AbstractEvent, f)
            @test handlers(c, MessageCreate) == [
                collect(c.handlers[AbstractEvent]);
                collect(c.handlers[MessageCreate]);
            ]

            # The fallback handler should only match if there's nothing else.
            add_handler!(c, FallbackEvent, f)
            @test handlers(c, MessageCreate) == [
                collect(c.handlers[AbstractEvent]);
                collect(c.handlers[MessageCreate]);
            ]
            delete_handler!(c, MessageCreate)
            @test handlers(c, MessageCreate) == collect(c.handlers[AbstractEvent])
            add_handler!(c, MessageCreate, f)
            delete_handler!(c, AbstractEvent)
            @test handlers(c, MessageCreate) == collect(c.handlers[MessageCreate])
            delete_handler!(c, MessageCreate)
            @test handlers(c, MessageCreate) == collect(c.handlers[FallbackEvent])

            # Expired handlers should be cleaned up.
            first(c.handlers[FallbackEvent]).expiry = 0
            @test isempty(handlers(c, MessageCreate))
            @test isempty(c.handlers[FallbackEvent])
        end
    end

    @testset "State" begin
        @testset "insert_or_update!" begin
            d = Dict()
            v = Bar[]

            # Inserting a new entry works fine.
            b = Bar(1, 2, 3)
            insert_or_update!(d, b.id, b)
            @test d[b.id] == b
            # But when we insert a value with the same ID, it's merged.
            b = Bar(1, 3, 3)
            insert_or_update!(d, b.id, b)
            @test d[b.id] == b
            b = Bar(1, 10, missing)
            insert_or_update!(d, b.id, b)
            @test d[b.id] == Bar(b.id, b.x, 3)

            # We can also insert/update without specifying the key, :id is inferred.
            b = Bar(2, 2, 1)
            insert_or_update!(d, b)
            @test d[b.id] == b
            b = Bar(2, 1, missing)
            insert_or_update!(d, b)
            @test d[b.id] == Bar(b.id, b.x, 1)

            # We can also do this on lists.
            b = Bar(1, 2, 3)
            insert_or_update!(v, b.id, b)
            @test length(v) == 1 && first(v) == b
            b = Bar(1, 10, missing)
            insert_or_update!(v, b.id, b)
            @test length(v) == 1 && first(v) == Bar(b.id, b.x, 3)
            b = Bar(1, 2, 2)
            insert_or_update!(v, b)
            @test length(v) == 1 && first(v) == b

            # If we need something fancier to index into a list, we can use a key function.
            b = Bar(1, 4, 5)
            insert_or_update!(v, b.id, b; key=x -> x.y)
            # We inserted a new element because we looked for an element with y == b.id.
            @test length(v) == 2 && last(v) == b
            # If we leave out the insert key, the key function is used on the value too.
            b = Bar(1, 0, 5)
            # We updated the value with y == b.y.
            insert_or_update!(v, b; key=x -> x.y)
            @test length(v) == 2 && last(v) == b
        end
    end
end
