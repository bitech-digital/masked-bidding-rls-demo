-- Masked-bidding marketplace pattern: enforcement lives in the database, not the UI.
-- Postgres 14+. Run: psql -f schema.sql

BEGIN;

CREATE SCHEMA IF NOT EXISTS mkt;

CREATE TABLE mkt.dealers (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL
);

CREATE TABLE mkt.listings (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title            text NOT NULL,
  status           text NOT NULL DEFAULT 'open' CHECK (status IN ('open','accepted','closed')),
  accepted_bid_id  uuid NULL
);

CREATE TABLE mkt.bids (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id  uuid NOT NULL REFERENCES mkt.listings(id),
  dealer_id   uuid NOT NULL REFERENCES mkt.dealers(id),
  amount      numeric(12,2) NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (listing_id, dealer_id)
);

ALTER TABLE mkt.listings
  ADD CONSTRAINT fk_accepted_bid FOREIGN KEY (accepted_bid_id) REFERENCES mkt.bids(id);

-- The application sets the caller's identity per transaction:
--   SET LOCAL app.role = 'dealer' | 'seller' | 'admin';
--   SET LOCAL app.dealer_id = '<uuid>';   (dealers only)
-- With Supabase this maps 1:1 onto auth.uid() and JWT claims; the policies are identical in shape.

CREATE OR REPLACE FUNCTION mkt.current_role_name() RETURNS text
  LANGUAGE sql STABLE AS $$ SELECT current_setting('app.role', true) $$;

CREATE OR REPLACE FUNCTION mkt.current_dealer_id() RETURNS uuid
  LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.dealer_id', true), '')::uuid $$;

ALTER TABLE mkt.bids    ENABLE ROW LEVEL SECURITY;
ALTER TABLE mkt.bids    FORCE  ROW LEVEL SECURITY;
ALTER TABLE mkt.dealers ENABLE ROW LEVEL SECURITY;
ALTER TABLE mkt.dealers FORCE  ROW LEVEL SECURITY;

-- RULE 1: a dealer sees ONLY their own bid rows. Not other amounts, not other identities.
CREATE POLICY dealer_own_bids ON mkt.bids
  FOR SELECT USING (
    mkt.current_role_name() = 'dealer' AND dealer_id = mkt.current_dealer_id()
  );

-- RULE 2: a dealer may insert only as themselves.
CREATE POLICY dealer_insert_self ON mkt.bids
  FOR INSERT WITH CHECK (
    mkt.current_role_name() = 'dealer' AND dealer_id = mkt.current_dealer_id()
  );

-- RULE 3: admin sees everything.
CREATE POLICY admin_all_bids ON mkt.bids
  FOR ALL USING (mkt.current_role_name() = 'admin');

-- RULE 4: dealer identities are visible to admin only; a dealer may read their own row.
CREATE POLICY dealer_self ON mkt.dealers
  FOR SELECT USING (
    mkt.current_role_name() = 'admin'
    OR (mkt.current_role_name() = 'dealer' AND id = mkt.current_dealer_id())
  );

-- RULE 5: the seller never touches the tables. The seller-facing surface is this view,
-- which is STRUCTURALLY UNABLE to emit dealer identity before acceptance:
-- the dealer join only produces a name for the single accepted bid.
-- (The view deliberately runs with owner privileges: it must aggregate ALL bids to
-- rank them for the seller, while its SELECT list is what withholds identity.)
CREATE OR REPLACE VIEW mkt.seller_bid_board WITH (security_barrier) AS
SELECT
  b.listing_id,
  rank() OVER (PARTITION BY b.listing_id ORDER BY b.amount DESC) AS bid_rank,
  b.amount,
  CASE WHEN l.accepted_bid_id = b.id THEN d.name ELSE NULL END   AS dealer_name_if_accepted
FROM mkt.bids b
JOIN mkt.listings l ON l.id = b.listing_id
LEFT JOIN mkt.dealers d
  ON d.id = b.dealer_id AND l.accepted_bid_id = b.id;

-- Seller role gets the view and nothing else.
CREATE ROLE app_seller NOLOGIN;
CREATE ROLE app_dealer NOLOGIN;
CREATE ROLE app_admin  NOLOGIN;

GRANT USAGE ON SCHEMA mkt TO app_seller, app_dealer, app_admin;
GRANT SELECT ON mkt.seller_bid_board TO app_seller;
GRANT SELECT, INSERT ON mkt.bids TO app_dealer;
GRANT SELECT ON mkt.dealers TO app_dealer;
GRANT ALL ON ALL TABLES IN SCHEMA mkt TO app_admin;

COMMIT;
