---
title: "Building MarginCMS, part 1: Contract first, code later"
description: "Why I'm building a small CMS in Go, and why the OpenAPI contract came before any code: a split spec, mocks and types for the frontend, and a plan for the backend."
date: 2026-10-05
tags: [go, openapi, margincms]
series: "Building MarginCMS"
source_url: "https://github.com/davidporos92/margin-cms/tree/part-1"
---

I'm building a small CMS in Go. It's called MarginCMS, it has a React admin on top, and it won't replace anything I already use. This series is the build log: what I decided, what I wrote, and what tripped me up along the way.

This first part covers why I'm doing it, and the work that happened before writing any Go code: the API contract, the tooling around it, and the plan for the backend.

The code is public at [github.com/davidporos92/margin-cms](https://github.com/davidporos92/margin-cms).

## Why build a CMS in 2026?

Nobody needs another CMS, including me. I'm building one anyway, for four reasons.

**It's fun.** Writing a CMS has been on my someday list for years, and a pet project with no deadline and no users is the best place to finally do it.

**AI made me rusty.** I use AI tools every day, and they're good. But I noticed that I reach for them before I've thought a problem through, and that the details of Go I used to know by heart have become fuzzy. I want a project where I make the decisions and write the code myself, with AI as a reviewer and a rubber duck rather than the author.

**It starts easy and gets hard.** A CMS starts as CRUD over a `posts` table, which is a nice way to ease back in. Then the real problems show up: authentication and token refresh, revision history, two people editing the same post at the same time, search, pagination. Each of these is small enough to finish and deep enough to learn something from.

**There's a lot of room to grow.** Once the core works, there's room for tools, plugins and packages around it: an export pipeline to my existing blog, a CLI, maybe a client library. None of that is planned yet, but the option is there.

My wife is building the React frontend, so this is a two-person project with a clean split: I own the Go API, she owns the web app and the design system. The only thing we share is the API contract (and a [small little doggo](https://www.instagram.com/pck.kalandjai)), and that shapes almost every decision below.

## The scope, briefly

To keep it finishable, v1 is deliberately boring:

- one admin user, one content type (posts), no media uploads, no plugin system
- posts are markdown with a title, slug, excerpt, tags and a status (`draft`, `published`, `archived`)
- every content change creates a revision, and an activity log records who did what
- one Go binary with small internal packages (`auth`, `posts`, `revisions`, `activity`, `stats`)

"Modular" here means compile-time packages with small interfaces, not a dynamic content-type builder.

## Step 1: Write the OpenAPI contract first

**Commit:** [Add OpenAPI contract and spec tooling](https://github.com/davidporos92/margin-cms/commit/065a09c)

Before writing a single handler, I wrote the API as an OpenAPI 3 spec. That had two goals.

**Don't block the frontend.** If the frontend has to wait for my endpoints, it'll wait a long time. With a spec in place, the frontend can generate its TypeScript types and develop against a mock server from day one, and switch the base URL once the real endpoints land.

**Get a clear picture of what I'm building.** Writing the contract forced decisions I would otherwise have made halfway through a handler:

- **Auth:** a short-lived access token in `Authorization: Bearer`, plus a single-use refresh token. No cookies, so classic CSRF doesn't apply; XSS is the thing to guard against instead.
- **Errors:** every error is `application/problem+json` (RFC 9457), with field-level details for form validation.
- **Optimistic concurrency:** posts carry an `ETag`, and updates, deletes and revision restores require `If-Match`. A stale write gets `412 Precondition Failed` with the current version of the post in the response, so the UI can show a proper conflict banner instead of silently overwriting someone's work.
- **Pagination:** cursor-based, not offset-based.

The result is 17 operations across auth, posts (including bulk actions and markdown export), revisions, tags, activity, stats and a health check.

I didn't want one 2,000-line YAML file, so the spec is split into small files: one per path and one per component (schemas, parameters, request bodies, responses), all referenced from a root `openapi.yaml`. The convention is simple: file name equals component name. `components/schemas/Post.yaml` defines `Post`. A bundler merges everything into a single file for the tools that need one.

## Step 2: Set up tooling around the spec

A spec is only useful if the tooling around it is easy to use, so the same commit adds npm scripts and `make` targets for:

| Need | Tool |
| --- | --- |
| Lint the spec | [Redocly CLI](https://redocly.com/docs/cli/) (`redocly lint`) |
| Bundle the split files into one | Redocly CLI (`redocly bundle`) |
| Browse the docs | Redocly |
| Mock server | [Prism](https://stoplight.io/open-source/prism) |
| TypeScript types | [openapi-typescript](https://openapi-ts.dev/) |
| Go types and server | [oapi-codegen](https://github.com/oapi-codegen/oapi-codegen) (wired up in part 2) |

Prism deserves a special mention. Besides returning example responses, it supports the `Prefer` header. The frontend can send `Prefer: code=412` and get a 412 back, which makes it possible to build the conflict handling long before the backend can produce a real conflict.

## Step 3: Plan the Go backend

No commit for this one. It's the thinking that happened before the code.

I picked tools in three groups.

**The HTTP server.** I went with [chi](https://github.com/go-chi/chi). I've used it before, it stays close to `net/http`, and oapi-codegen can generate a chi server directly from the spec. More on that in part 2.

**Data access.** The classic Go debate is ORM versus plain SQL. Since part of the point is to learn new things while I ease back into Go, I chose tools I haven't used in anger yet:

- **PostgreSQL** with [pgx](https://github.com/jackc/pgx)
- **[Ent](https://entgo.io/)** for the schema and data access, with the schema written as Go code
- **[Atlas](https://atlasgo.io/)** to generate versioned SQL migrations from the Ent schema. The API never changes the database schema on its own.
- **[testcontainers-go](https://golang.testcontainers.org/)** for integration tests against a real Postgres, using the same migration files that ship

**Code generation from OpenAPI.** Handlers implement an interface generated from the spec, so the code can't drift from the contract without the compiler noticing.

## Step 4: Plan the local dev setup

Also mostly planning at this stage. The goal was a dev loop where everything runs with one command:

- **Go hot reload** with [Air](https://github.com/air-verse/air), so saving a file rebuilds and restarts the API
- **Prism** as the mock backend for the web app, for the `Prefer` header support mentioned above
- **Docker Compose** so we both get the same environment, including Postgres later

## Next steps

In [part 2]({% post_url margincms/2026-10-07-building-margincms-part-2-a-go-server-generated-from-the-spec %}) I set up the Go service and the local environment: generating the server from the spec, config handling, stub handlers, the Docker Compose setup, and a CORS bug that turned out to be a library quirk, not the protocol.
