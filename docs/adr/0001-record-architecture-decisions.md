# 1. Record architecture decisions

Date: 2026-06-26

## Status

Accepted

## Context

We need to record the architectural decisions made on this project, so that
the reasoning behind them is preserved as the project evolves and as people
(or agents) pick the work back up later.

## Decision

We will use Architecture Decision Records, as described by Michael Nygard, kept
as Markdown files in `docs/adr/`. Each significant decision gets a numbered file
(`NNNN-short-title.md`) using `template.md` as the starting point.

A decision is "significant" when it constrains future work or would be expensive
to reverse: choice of framework/runtime, data model, IPC/network boundaries,
auth model, build/release approach, or any notable tradeoff.

## Consequences

The history of why the system is shaped the way it is stays with the code. New
contributors read the ADR log instead of reverse-engineering intent. The cost is
the small discipline of writing one short record per significant decision.
