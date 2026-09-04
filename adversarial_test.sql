-- Adversarial suite: every block ATTEMPTS a leak and FAILS LOUDLY if one occurs.
-- Run after schema.sql:  psql -f adversarial_test.sql
-- Output ends with: ALL ADVERSARIAL TESTS PASSED

BEGIN;

-- Seed: one listing, three dealers, three bids.
INSERT INTO mkt.dealers (id, name) VALUES
  ('11111111-1111-1111-1111-111111111111','Alpha Motors'),
  ('22222222-2222-2222-2222-222222222222','Beta Autos'),
  ('33333333-3333-3333-3333-333333333333','Gamma Cars');

INSERT INTO mkt.listings (id, title) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','2019 family sedan');

SET LOCAL app.role = 'admin';
SET LOCAL ROLE app_admin;
INSERT INTO mkt.bids (listing_id, dealer_id, amount) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','11111111-1111-1111-1111-111111111111', 41000),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','22222222-2222-2222-2222-222222222222', 43500),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','33333333-3333-3333-3333-333333333333', 42250);

---------------------------------------------------------------------------
-- TEST 1: dealer Alpha tries to read competitor bid rows. Expect exactly 1 row (their own).
---------------------------------------------------------------------------
RESET ROLE;
SET LOCAL app.role = 'dealer';
SET LOCAL app.dealer_id = '11111111-1111-1111-1111-111111111111';
SET LOCAL ROLE app_dealer;  -- non-superuser: RLS applies, no bypass

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM mkt.bids;
  IF n <> 1 THEN RAISE EXCEPTION 'LEAK: dealer sees % bid rows, expected 1', n; END IF;
END $$;

---------------------------------------------------------------------------
-- TEST 2: dealer Alpha tries to enumerate competitor identities. Expect only their own row.
---------------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM mkt.dealers;
  IF n <> 1 THEN RAISE EXCEPTION 'LEAK: dealer sees % dealer identities, expected 1', n; END IF;
END $$;

---------------------------------------------------------------------------
-- TEST 3: dealer Alpha tries to bid AS Beta. Expect the insert to be rejected.
---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO mkt.bids (listing_id, dealer_id, amount)
    VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','22222222-2222-2222-2222-222222222222', 1);
    RAISE EXCEPTION 'LEAK: dealer inserted a bid under another dealer identity';
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    NULL; -- correctly blocked
  END;
END $$;

---------------------------------------------------------------------------
-- TEST 4: seller board BEFORE acceptance: ranked amounts visible, ALL identities NULL.
---------------------------------------------------------------------------
RESET ROLE;
SET LOCAL app.role = 'seller';
SET LOCAL app.dealer_id = '';
SET LOCAL ROLE app_seller;

DO $$
DECLARE leaked int; rows int;
BEGIN
  SELECT count(*), count(dealer_name_if_accepted) INTO rows, leaked FROM mkt.seller_bid_board;
  IF rows <> 3 THEN RAISE EXCEPTION 'WRONG: seller sees % ranked bids, expected 3', rows; END IF;
  IF leaked <> 0 THEN RAISE EXCEPTION 'LEAK: % dealer identities visible before acceptance', leaked; END IF;
END $$;

---------------------------------------------------------------------------
-- TEST 5: seller accepts the top bid; EXACTLY ONE identity becomes visible, the winner's.
---------------------------------------------------------------------------
RESET ROLE;
SET LOCAL app.role = 'admin';
SET LOCAL ROLE app_admin;
UPDATE mkt.listings
   SET accepted_bid_id = (SELECT id FROM mkt.bids WHERE amount = 43500),
       status = 'accepted'
 WHERE id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

RESET ROLE;
SET LOCAL app.role = 'seller';
SET LOCAL ROLE app_seller;
DO $$
DECLARE winner text; visible int;
BEGIN
  SELECT count(dealer_name_if_accepted) INTO visible FROM mkt.seller_bid_board;
  IF visible <> 1 THEN RAISE EXCEPTION 'LEAK: % identities visible after acceptance, expected 1', visible; END IF;
  SELECT dealer_name_if_accepted INTO winner FROM mkt.seller_bid_board WHERE dealer_name_if_accepted IS NOT NULL;
  IF winner <> 'Beta Autos' THEN RAISE EXCEPTION 'WRONG: revealed identity is %, expected the winner', winner; END IF;
END $$;

SELECT 'ALL ADVERSARIAL TESTS PASSED' AS result;

ROLLBACK; -- demo leaves no data behind
