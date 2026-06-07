---
name: share-research-as-chat-message
group: writing-format
summary: "Rewrites research into forwardable chat message (default Danish): sharp opener, compressed answer, sources."
description: Rewrite a researched answer, findings summary, or another model's output into a chat message that is easy to forward. Use when the user wants a sharper intro framed like "Jeg tænkte på ...", a short divider such as "Her er hvad Gemini fandt ud af", a shorter and less chatty answer, selectable output language, and strict fact-checking with current sources for every factual point.
---

# Share Research As Chat Message(default: Danish)

Turn research into a message that reads like something the user would actually send in chat.
Keep the structure fixed, keep the prose compact, choose the output language correctly, and verify every factual claim against current sources before writing the final answer.

## Workflow

1. Identify the source material.
Determine whether the user has provided:
- their original concern or question,
- if none given, suggest questions that are answered by the provided research,
- an existing answer that should be compressed and checked.

2. Resolve the output language first.
Default to Danish if the user does not specify any output language and no other language is requested or suggested.
If the user mentions another language, multiple possible languages, translation, or wording that makes the target language ambiguous, stop and require an explicit output language before drafting the message.
Once resolved, write the entire output in that single target language, including the opening block, divider, answer, and source label.

3. Rebuild the opening block in the target language.
Write the opening as the user's own framing, not as a neutral summary.
Make it slightly sharper and slightly more detailed than the original.
Add a few concrete sub-points or worries that the answer will address.
Do not invent emotional claims that are not supported by the original context.
In Danish, prefer a neutral lead-in such as `Jeg taenkte på ...` unless the user clearly frames it as a concern.

4. Fact-check before rewriting the answer.
Use current sources for every factual point that survives into the final answer.
Prefer primary sources first:
- official documentation,
- company or government pages,
- original research or dataset owners,
- standards bodies,
- earnings releases or filings for company claims.
Use secondary sources only when a primary source is unavailable or insufficient.
If a point cannot be verified confidently, omit it or rewrite it as uncertainty.

5. Check recency explicitly.
Assume facts may have changed.
Verify dates, prices, releases, leadership, policies, laws, schedules, product details, and recommendations against fresh sources.
When time-sensitive facts are included, anchor them with concrete dates instead of vague words like "now" or "recently".

6. Rewrite the answer for chat.
The answer section must be shorter and less chatty than the source.
Keep it readable, but strip filler, hedging, stage-setting, and repetition.
Prefer short paragraphs or very light bullets only when they improve scanability.

## Output Contract

Return a ready-to-send chat message in the resolved target language with this shape:

1. Opening block in the target language.
This is written from the user's point of view and can be slightly longer and sharper than the original.
In Danish, prefer neutral phrasing such as `Jeg taenkte på ...` over `Jeg er bekymret for ...` unless the source clearly calls for stronger wording.

2. A single breaker line in the target language.
If the user does not specify otherwise, use a natural equivalent of `Here is what Gemini found out`.

3. A compressed answer block in the target language.
Keep the answer factual, direct, and easy to paste into chat.

4. A short source tail.
End with the target-language equivalent of `Links:` followed by a compact list of the sources that support the claims actually used.
Use Markdown links when links are available.
Do not attach sources to claims that were removed from the final answer.

## Style Rules

- Write in natural language for the chosen target language.
- Keep the tone plain, informed, and unsentimental.
- Do not sound like an AI assistant.
- Do not mention the fact-checking workflow unless the user asks for it.
- Do not use marketing language or exaggerated certainty.
- Do not preserve chatty phrases from the source if they weaken the message.
- If the original answer is long, extract only the points that matter for the user's concern.

## Verification Rules

- Every factual sentence in the final answer must be supported by at least one checked source.
- When multiple sources disagree, resolve the conflict before answering or state the uncertainty clearly.
- Prefer the most recent authoritative source when facts have changed over time.
- Preserve only facts you can defend.
- If the user explicitly asks for "up to date", "latest", "today", or similar, always verify with fresh sources.

## Fallbacks

If the provided answer is weak or wrong:
- keep the user's opening block,
- rebuild the answer from verified sources,
- keep the final answer shorter than a normal research summary.

If the user provides only a raw question:
- infer the opening block from that question,
- research the answer,
- then return the final chat-ready version in the same structure.

If the language is ambiguous:
- ask for one explicit target language,
- do not draft the final message until the user answers.

If the topic is highly time-sensitive or high-stakes:
- tighten the wording,
- include specific dates where useful,
- avoid any claim that is not well sourced.

## Example Skeletons

### Example in English
```markdown
[Sharpened opening block in English]

Here is what Gemini found out:

[Short, tight, source-checked answer block in English]

Links: [Source 1](https://example.com), [Source 2](https://example.com)
```

### Example in Danish
```markdown
[Skaerpet åbningsblok på dansk]

Her er hvad Gemini fandt ud af:

[Kort, stram og verificeret svarblok på dansk]

Links: [Kilde 1](https://example.com), [Kilde 2](https://example.com)
```
