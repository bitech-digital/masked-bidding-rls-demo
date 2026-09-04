# Masked-bidding, enforced in the database

A minimal working demonstration of the permission pattern behind masked-bid
marketplaces (sellers see ranked bids with bidder identity hidden until they
accept one; bidders never see each other's bids or identities).

The point of the demo: **masking is a property of the data layer, not the UI.**

- Bidders read the `bids` table through row-level security: the only row that
  exists, from their side, is their own.
- Bidder identities are equally invisible: a bidder cannot even enumerate who
  else is on the platform.
- The seller never touches tables at all. Their surface is a view that is
  *structurally unable* to emit a bidder's name before acceptance: the identity
  join only produces a value for the single accepted bid.
- An adversarial suite attempts the leaks (read competitors' bids, enumerate
  identities, bid as someone else, unmask pre-acceptance) and fails loudly if
  any succeed.

## Run it

Postgres 14+ (or `docker run --rm -e POSTGRES_PASSWORD=x -p 5432:5432 postgres:16`):

```
psql -h localhost -U postgres -f schema.sql
psql -h localhost -U postgres -f adversarial_test.sql
```

Expected final output:

```
            result
------------------------------
 ALL ADVERSARIAL TESTS PASSED
```

The identity plumbing here uses `set local` session settings so the demo runs
on bare Postgres; on Supabase the same policies bind to `auth.uid()` and JWT
claims with identical shape.

Muneeb Ashraf, BiTech Digital.
