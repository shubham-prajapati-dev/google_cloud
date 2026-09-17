-- Run as the built-in postgres administrator.
-- Replace IAM_USER_EMAIL with the Cloud IAM principal created in the lab.

\c orders

GRANT ALL PRIVILEGES ON TABLE order_items TO "IAM_USER_EMAIL";

-- Verification queries (run after connecting as the IAM user):
-- SELECT COUNT(*) FROM order_items;
-- SELECT COUNT(*) FROM users;
-- The first query should be permitted after the grant; the second should
-- remain denied when no privileges have been granted on users.
