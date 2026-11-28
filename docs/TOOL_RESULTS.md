# Spoken tool results

Listen is a general client. It does not know what a TV, a lamp, a calendar or a media
library means by its results. When a voice session reports an observed tool result,
Listen says either the service's own sentence or a neutral sentence for the observed
state. What an outcome means stays with the MCP server that owns the service.

## The contract

A server opts in with one reserved object in its structured result (`structuredContent`,
or a JSON object as the text content):

```json
{
  "outcome": "anything the service uses",
  "spoken": {"status": "unreachable", "text": "I can't reach the TV right now.", "language": "en"}
}
```

| Field | Meaning |
| --- | --- |
| `status` | Required. One of the neutral statuses below. |
| `text` | Optional. The sentence to say, written by the server. |
| `language` | Required with `text`. The language of `text`, for example `de` or `de-CH`. |

Other fields of the result stay the service's own data. Unknown fields inside `spoken`
are ignored, so the contract can grow without breaking older versions of Listen.

Why one reserved object instead of top-level fields: services already use names such as
`status` or `speech` for their own meanings. A generic client must not misread them.

## Statuses

| Status | Means | Listen's own sentence (English) |
| --- | --- | --- |
| `done` | The requested effect is confirmed. | Done. |
| `partial` | Some targets are done, others are not. | That only partly worked. Check the details. |
| `info` | A lookup answered; nothing was changed. | The answer is here. Details are available in the app. |
| `unconfirmed` | Sent, but the effect is not confirmed. | It was sent, but it is not confirmed. I will not repeat it. |
| `failed` | Tried and not done. | The service reported an error. Check the details. |
| `unavailable` | The target or content does not exist there. | That is not available there. |
| `unreachable` | The device or service cannot be reached. | I can't reach the service right now. |
| `needs_choice` | Several targets match; the user has to choose. | The service needs a more specific choice. Can you be more specific? |
| `needs_confirmation` | An alternative is offered; nothing was done. | The service offers an alternative. Nothing has been done yet. Check the details. |

German sentences exist for every status as well.

## What Listen does with it

- **The service's sentence:** Listen speaks `text` only when `language` matches the session language and the text is plain: at most 300 characters, one paragraph, and no links, markup, code characters (`{}[]<>` backtick backslash), control, format or private-use characters. Otherwise Listen says its own sentence for the status.
- **Failures:** MCP `isError` stays authoritative. A failed call that reports `done` or `info` is outside the contract. A successful call may report any status, because a service can describe a typed failure without failing the call.
- **Invalid reports:** an unknown or differently spelled status, duplicate JSON keys, a result over 8 KiB and plain text all fall back to the generic sentence for the observed state.
- **What the text never does:** it grants no permission, confirms no pending action, starts no tool and triggers no retry. Confirmation of actions stays with Listen's own permission flow. A follow-up such as "yes, start the alternative" is a new request that goes through that flow.
- **Results outside the contract:** Listen says "The service has responded. Details are available in the app." for a success and "The service reported an error. Check the details." for a failure. The full result stays available to the model and in the app, as before.

Listen cannot verify that a service's sentence is true. It trusts the servers the owner
connected only as far as their own reports; the status and the `isError` flag bound what
those reports can claim.
