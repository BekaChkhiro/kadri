# NETA — AI repair guide in your camera

NETA (working name „კადრი“) is a native iOS app that turns a photo into a step-by-step repair or assembly guide, in Georgian.
Photograph the object, describe the problem, and the AI marks the parts on the photo and walks you through the fix.

[![NETA demo video](https://img.youtube.com/vi/1h_iX-sqAmE/maxresdefault.jpg)](https://youtu.be/1h_iX-sqAmE)

▶︎ **Demo:** https://youtu.be/1h_iX-sqAmE

## What it does

- **Photo → parts → steps.** The AI finds the parts (sink trap, washing machine, car engine, PC build…) and streams steps one by one.
- **On the exact part.** Pins and target frames, rotate / press / lift arrows, tightening order, and what *not* to touch.
- **Tools with honest sizes.** A size is marked **confirmed** only when it's readable on the photo or comes from the model's spec.
  Otherwise it's **likely, check**, with a quick way to verify it, e.g. "start with 10 mm; if it turns loosely, try 11".
- **Check photos.** After risky steps (CPU lever, RAM click, connectors) the AI asks for a close-up photo instead of trusting "yes, done".
- **Questions both ways.** The AI asks multiple-choice questions when it needs them. You can tap any part on the photo and ask about it.
- **Multi-photo problems.** Send several photos of one problem and NETA links the same part across views.

Core principle: **the AI never pretends to know.** Anything unverified is labelled as a guess, and the app tells you how to check it yourself.

## Stack

| Layer | Tech |
|---|---|
| iOS app | SwiftUI, iOS 17+, local Swift package `KadriCore` (models, API client, SSE, session logic), Google Sign-In |
| Backend | Cloudflare Workers (TypeScript), D1, R2, per-user daily limits and cost tracking |
| AI | Gemini and OpenAI behind one strict JSON-schema contract. Server-side validation downgrades unverified claims. Knowledge Hub lookup for model-specific facts |
| On-device | SAM encoder/decoder in Core ML for part outlines |

Built with coding agents (Claude Code, Codex).

---

Hacktoberfest 2026 · team **Hamburger** · track 03 Mobile native
