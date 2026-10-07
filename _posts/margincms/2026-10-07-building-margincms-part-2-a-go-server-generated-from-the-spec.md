---
title: "Building MarginCMS, part 2: A Go server generated from the spec"
description: "Generating a typed chi server from the OpenAPI spec with oapi-codegen, stub handlers that return 501, a one-command Docker Compose setup, and a CORS bug that hid every response."
tags: [go, openapi, docker, margincms]
date: 2026-10-07
series: "Building MarginCMS"
source_url: "https://github.com/davidporos92/margin-cms/tree/part-2"
---

In [part 1]({% post_url margincms/2026-10-05-building-margincms-part-1-contract-first-code-later %}) I wrote the OpenAPI contract for MarginCMS and planned the backend. In this part the Go service comes to life: a server generated from the spec, config from environment variables, stub handlers that fail properly, and a Docker Compose setup that runs the API, the docs and a mock server with one command.

It also includes a CORS bug where my server logged every request and the browser still showed nothing. That one gets its own section.

## Why generate the server at all?

The contract is the only thing my wife's frontend and my backend share. If the Go handlers are written by hand, they'll drift from the spec sooner or later: a renamed field, a missing status code, a query parameter parsed as the wrong type. With a generated server, the handlers implement an interface that comes straight from the spec. When the spec changes, I regenerate, and the compiler tells me exactly what's out of date.

## Step 1: Choose the server and generate it from the spec

**Commit:** [api: generate Go server and types from the OpenAPI spec](https://github.com/davidporos92/margin-cms/commit/4ca2fb4)

### chi

I picked [chi](https://github.com/go-chi/chi) as the router:

- I've used it before, so it's one less new thing.
- It's a thin layer on top of `net/http`. Handlers are plain `http.Handler`s, and anything from the standard library works with it.
- It has a good community and plenty of middleware and packages, including the CORS package that shows up later in this post.

### oapi-codegen

[oapi-codegen](https://github.com/oapi-codegen/oapi-codegen) turns the bundled spec into Go code. I generate four files, each from its own small config:

| Config | Generates |
| --- | --- |
| `models.yaml` | Request and response types |
| `server.yaml` | A chi server and a *strict* server interface |
| `client.yaml` | A typed Go client, useful for tests later |
| `server_urls.yaml` | Constants for the server URLs in the spec |

The strict server is the important part. Instead of `func(w http.ResponseWriter, r *http.Request)`, each operation becomes a method with typed input and typed output:

```go
func (s server) GetHealth(ctx context.Context, request api.GetHealthRequestObject) (api.GetHealthResponseObject, error)
```

The generated code parses the path, query, headers and body, calls my method, and writes the response. My code never touches `http.Request`. The return type is an interface that the generated per-status response types implement, so returning a response the spec doesn't define takes deliberate effort instead of happening by accident.

### Empty string or no field at all?

A few years ago I worked with code generated from proto3 messages with plain `string` fields. Without the `optional` keyword (generally available only since protobuf 3.15) or wrapper types like `StringValue`, proto3 can't tell the difference between a client sending `"title": ""` and not sending `title` at all. Both arrived as an empty string. For a `PATCH` endpoint that's a real problem: "clear the excerpt" and "don't touch the excerpt" look the same.

oapi-codegen handles this the Go way. Optional fields become pointers:

```go
type PostUpdate struct {
	Body    *string     `json:"body,omitempty"`
	Excerpt *string     `json:"excerpt,omitempty"`
	Slug    *string     `json:"slug,omitempty"`
	Status  *PostStatus `json:"status,omitempty"`
	Tags    *[]string   `json:"tags,omitempty"`
	Title   *string     `json:"title,omitempty"`
}
```

`nil` means "not sent", and a pointer to `""` means "set it to empty" (for `excerpt` and `body`; `title` has `minLength: 1`). That's exactly what the `PATCH` semantics need.

One caveat: an explicit `"excerpt": null` also decodes to `nil`, so "not sent" and "sent as null" look the same. That's fine here because none of these fields are nullable. If I ever need the difference, oapi-codegen's `nullable-type` output option generates `nullable.Nullable[T]` for it.

### Tools pinned with `go tool`

My first version installed the generator with `go install ...@latest`. That works on my machine today, but it means anyone cloning the repo next year gets a different generator than the one that produced the committed code.

Since Go 1.24, `go.mod` can track tools the same way it tracks dependencies:

```
tool (
	github.com/air-verse/air
	github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen
)
```

Now `go tool oapi-codegen` always runs the exact version in `go.mod`, and the root `Makefile` uses it:

```make
openapi-generate-go:
	cd api && go tool oapi-codegen --config=../openapi/oapi-codegen/server.yaml ../openapi/dist/openapi.bundled.yaml
```

The trade-off is that the tools' dependencies show up in `go.mod` as indirect requirements. They don't end up in the API binary, but the file gets longer. I'm fine with that in exchange for one source of truth for versions.

## Step 2: Config, stubs and a health check

**Commit:** [api: add server skeleton with config, stub handlers and health check](https://github.com/davidporos92/margin-cms/commit/ae3c5d7)

### Config from the environment

Config comes from environment variables, mapped onto structs with [go-envconfig](https://github.com/sethvargo/go-envconfig). Each package owns its own config struct, and the top-level config just composes them:

```go
// internal/server/config.go
type Config struct {
	Addr              string        `env:"SERVER_ADDR, default=:8080"`
	ShutdownTimeout   time.Duration `env:"SERVER_SHUTDOWN_TIMEOUT, default=30s"`
	ReadHeaderTimeout time.Duration `env:"SERVER_READ_HEADER_TIMEOUT, default=5s"`
	// ...
}

// internal/config/config.go
type Config struct {
	Server *server.Config
}
```

When the database and auth packages arrive, they'll add their own `Config` next to their code instead of one giant struct growing in a single file.

There's also a test that loads the config with no `SERVER_*` variables set and compares it with the expected defaults. It sounds trivial, but it's already caught me twice: once when I added the CORS and timeout fields, and once when I lowered a timeout default. Defaults are part of the behaviour, so they deserve a test. It also makes me look at `.env.example` every time a default changes, so the code and the docs don't drift apart.

### `main.go`

`main.go` stays small: load the config, build the generated handler, wrap it, and run an `http.Server` with timeouts and graceful shutdown:

```go
ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
defer stop()

cfg := config.New(ctx)

serverInterface := api.NewStrictHandlerWithOptions(server.New(), server.NewServerMiddlewares(), server.NewServerOptions())
handler := api.HandlerWithOptions(serverInterface, api.ChiServerOptions{BaseURL: "/api/v1"})
```

On `SIGINT` or `SIGTERM` the server stops accepting new connections and gives in-flight requests up to `SERVER_SHUTDOWN_TIMEOUT` to finish.

### 501 for everything that isn't built yet

The generated interface has 17 methods, and I've implemented one. The stubs for the rest started out as `panic("implement me")`. Go's HTTP server recovers from the panic, but the client gets a dropped connection and my log gets a stack trace. Not great when the docs page has a "Try it" button.

`501 Not Implemented` is the honest answer. The catch is that the strict server only lets a method return the responses the spec defines, and the spec has no 501. It doesn't need one, though: any `error` a method returns goes to a configurable `ResponseErrorHandlerFunc`. So every stub returns a sentinel error:

```go
var ErrNotImplemented = errors.New("not implemented")

func (s server) ListPosts(ctx context.Context, request api.ListPostsRequestObject) (api.ListPostsResponseObject, error) {
	return nil, ErrNotImplemented
}
```

and the error handler maps it to a status code and writes a `problem+json` body using the `Problem` type generated from the spec:

```go
func responseErrorHandler(w http.ResponseWriter, r *http.Request, err error) {
	status := http.StatusInternalServerError
	if errors.Is(err, ErrNotImplemented) {
		status = http.StatusNotImplemented
	} else {
		log.Printf("%s %s %s", r.Method, r.URL.Path, err)
	}

	writeProblem(w, status)
}
```

A nice side effect: real errors returned from handlers now also come back as a clean `500` in the same format, and the internal error message is logged instead of being sent to the client. Request-decoding errors still get oapi-codegen's default plain-text 400 for now.

```
$ curl http://localhost:8080/api/v1/posts
{"status":501,"title":"Not Implemented","type":"about:blank"}
```

### Health check

`GET /api/v1/healthz` returns `{"status":"OK"}`. That's a stub for now. Once there's a database, it'll check that the app's dependencies are reachable and healthy, so Docker and any future deployment can tell a running process from a working one.

## Step 3: One command for the whole dev environment

**Commit:** [tooling: add Docker Compose dev environment](https://github.com/davidporos92/margin-cms/commit/a851c73)

`docker compose up` starts three services:

| Service | Port | What it is |
| --- | --- | --- |
| `api` | 8080 | The Go API, rebuilt on every save by [Air](https://github.com/air-verse/air) |
| `apidocs` | 8081 | `redocly preview`: the API docs with a "Try it" console |
| `apimock` | 8082 | Prism, serving mock responses from the spec |

The `api` container mounts the source code and runs `go tool air`, so Air is pinned in `go.mod` like the generator. Two named volumes keep the Go module cache and the build cache (which holds the compiled Air binary) between container restarts. Without them, every recreated container downloaded all modules and compiled Air from scratch before serving a single request.

### Do I still need Prism?

While setting this up, I noticed that the Redocly preview also has a built-in mock server behind its "Try it" console. So is Prism redundant?

Not for us. The Redocly mock is great for trying endpoints from the docs page. Prism is a standalone server on a fixed port that the React app can use as its backend while my endpoints are still returning 501. It also validates requests against the spec and supports the `Prefer` header, so the frontend can ask for a specific response, like `Prefer: code=412` for the edit-conflict case. That's what the frontend needs, so Prism stays.

## Step 4: The request that arrived and never came back

**Commit:** [api: add CORS middleware](https://github.com/davidporos92/margin-cms/commit/88a35c1)

With everything running, I opened the docs on `localhost:8081`, pointed the "Try it" console at my real API on `localhost:8080`, and called the health check. The API logged the request. The docs page showed no response at all.

### Part one: CORS

The server did its job. The browser threw the response away.

A different port is a different origin, so a page on `:8081` calling `:8080` makes a cross-origin request. A plain `GET` without custom headers is a "simple" request, so the browser sends it straight away without a preflight. My handler runs and returns 200. But the response has no `Access-Control-Allow-Origin` header, so the browser refuses to let the page read it. The devtools console says so, if you think to look there.

The fix is the [go-chi/cors](https://github.com/go-chi/cors) middleware. One detail matters: it has to run before chi's routing, so I wrap the whole handler at the `net/http` level instead of adding it to the strict server's middleware list. A preflight `OPTIONS` request doesn't match any generated route (chi answers 405 or 404 itself), so per-operation middleware never sees it.

```go
handler = cors.Handler(cors.Options{
	AllowedOrigins:   cfg.Server.AllowedOrigins,
	AllowedHeaders:   cfg.Server.AllowedHeaders,
	AllowedMethods:   cfg.Server.AllowedMethods,
	AllowCredentials: cfg.Server.AllowCredentials,
})(handler)
```

### Part two: `*` means "all methods" in the spec, but not in go-chi/cors

I added CORS, set everything to `*` in my local env to get going, and still got nothing.

Calling the API with `curl` and an `Origin` header showed the middleware was running, since the response had `Vary: Origin`, but there was still no `Access-Control-Allow-Origin`.

That surprised me, because `*` is a valid value for the [`Access-Control-Allow-Methods`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Access-Control-Allow-Methods) header: for requests without credentials, it means "all methods". The protocol was fine; the library was the problem. Reading the go-chi/cors source explained it. In its options, `*` is a wildcard for `AllowedOrigins` and `AllowedHeaders`, but not for `AllowedMethods`. There, `*` is compared literally against the request method, as if it were a method called `*`.

On top of that, go-chi/cors checks the method on the actual request too, not only on the preflight, which the CORS spec doesn't ask for. My `GET` was a simple request with no preflight, and `GET` wasn't in my list, so it got no CORS headers at all. A preflighted request wouldn't have fared better: the preflight checks the requested method against the same list, and on a mismatch it still answers `200 OK`, just without any CORS headers.

Even a library that passed `*` through wouldn't have saved this config, because I also had `AllowCredentials: true`. For requests with credentials (cookies, TLS client certificates or HTTP authentication), browsers treat `*` in `Access-Control-Allow-Methods` and `Access-Control-Allow-Headers` as a literal name. That setting had a problem of its own, which is part three.

Listing the methods explicitly fixed it:

```
SERVER_ALLOWED_METHODS="GET,POST,PUT,PATCH,DELETE,OPTIONS"
```

### Part three: don't ship the permissive version

While I was there, I noticed a config that only worked by accident. `AllowedOrigins: *` with `AllowCredentials: true` makes go-chi/cors send `Access-Control-Allow-Origin: *` next to `Access-Control-Allow-Credentials: true`, a combination browsers reject for credentialed requests. MarginCMS uses bearer tokens and no cookies, so it doesn't need credentials at all, and there's no reason to let every origin in either. The defaults are now strict:

```go
AllowedOrigins   []string `env:"SERVER_ALLOWED_ORIGINS, default=http://localhost:8081"`
AllowedMethods   []string `env:"SERVER_ALLOWED_METHODS, default=GET,POST,PUT,PATCH,DELETE,OPTIONS"`
AllowedHeaders   []string `env:"SERVER_ALLOWED_HEADERS, default=Authorization,Content-Type"`
AllowCredentials bool     `env:"SERVER_ALLOW_CREDENTIALS, default=false"`
```

If it works locally with `*`, that's a sign to tighten it, not a sign that you're done.

## What I'd tell myself before starting

- When the server says 200 and the client sees nothing, the browser is the one dropping the response. Start debugging there.
- Read the source of small middleware packages. go-chi/cors is a few hundred lines, and five minutes of reading beat an hour of guessing.
- Pin your code generators. Generated code is only reproducible if the generator version is.
- Test your defaults. It's the cheapest test you'll write and it keeps config and docs honest.

## Next steps

1. **Add a linter.** [golangci-lint](https://golangci-lint.run/) with a config that's strict from day one, while there's still almost no code to fix.
2. **Start on auth with mock data.** Login, token refresh, logout and `GET /me`, backed by an in-memory user for now, so the auth flow and its tests exist before the database does.
