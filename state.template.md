# Project state

The owner reads this on boot and updates it at the end of every job. A fact here outranks older
notes anywhere else in `.foreman/`. When the human answers a question, the answer goes in
**Human answers** the same turn, dated, so it is never asked again.

Last updated: (date, by whom)

## Live systems
| What | State | Since | How we know |
|---|---|---|---|
| Base branch on the remote | (commit) | | |
| Each live database: last migration applied | (e.g. 0007) | | (who confirmed it, how) |
| Deploy | (what is deployed, where) | | |

## Human answers (domain knowledge and decisions)
- (date) (the question, in a few words): (the answer)

## Waiting on the human
- (a migration to apply, a deploy step, a decision)

## Not yet verified
- (what no one has checked yet: a browser click-through, a real-model run, ...)

## Open work
- (jobs and fixes still to do)
