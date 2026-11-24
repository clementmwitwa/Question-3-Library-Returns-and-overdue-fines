-- ICT371 Advanced Database | Question 3: Library Returns and Overdue Fines
-- Student: Clement Mwitwa | Student No: 202406171 | PostgreSQL
-- Rule: fine = K2 per day after due_on; returning ON the due date costs K0.

DROP SCHEMA IF EXISTS q3_library CASCADE;
CREATE SCHEMA q3_library;
SET search_path = q3_library, public;

/* ===================== (a) Database and seed data ===================== */
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER       NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100)  NOT NULL,
    borrowed_on   DATE          NOT NULL,
    due_on        DATE          NOT NULL,
    returned_on   DATE          NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrowed CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INTEGER   NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE      NULL,
    new_returned_on  DATE      NULL,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER       NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Computer Networks'),
    ('Operating System Principles');

-- Six loans, all loaded OPEN; the returned ones are closed through pr_return_loan below.
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Alice Mulenga', CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open, overdue
    (2, 'Brian Tembo',   CURRENT_DATE - 10, CURRENT_DATE + 4),   -- 2 open, on time
    (1, 'Chanda Zulu',   CURRENT_DATE - 40, CURRENT_DATE - 26),  -- 3 returned late
    (3, 'Daniel Mwale',  CURRENT_DATE - 20, CURRENT_DATE - 6),   -- 4 open, overdue
    (2, 'Eve Lungu',     CURRENT_DATE - 15, CURRENT_DATE - 1),   -- 5 open, 1 day overdue
    (3, 'Faith Sakala',  CURRENT_DATE - 12, CURRENT_DATE - 2);   -- 6 returned on due date

/* ===================== (b) Function ===================== */
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    -- A returned loan stops accumulating fines: use the earlier of as-of date and return date.
    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));
    RETURN 2 * GREATEST(v_end - v_due, 0);      -- minimum zero, no fine on the due date
END;
$$;

/* ===================== (c) Procedure ===================== */
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_due      DATE;
    v_returned DATE;
    v_fine     NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;

    SELECT borrowed_on, due_on, returned_on INTO v_borrowed, v_due, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);   -- loan still open here, so p_returned_on is the end date

    -- Return date and final fine are stored together in ONE update.
    UPDATE loans SET returned_on = p_returned_on, fine_amount = v_fine WHERE loan_id = p_loan_id;
END;
$$;

/* ===================== (d) Trigger ===================== */
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)   -- no audit row if the date is unchanged
EXECUTE FUNCTION trg_fn_loan_audit();

/* ---- (a) continued: close the two returned loans via the procedure ---- */
CALL pr_return_loan(3, CURRENT_DATE - 20);   -- 6 days late  -> K12
CALL pr_return_loan(6, CURRENT_DATE - 2);    -- on due date  -> K0

SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;  -- 2 rows

-- Function tests (as of today)
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today FROM loans ORDER BY loan_id;
-- expected: 1->32, 2->0, 3->12 (stops at return), 4->12, 5->2, 6->0
DO $$ BEGIN PERFORM fn_loan_fine(99, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

-- Procedure rejections
DO $$ BEGIN CALL pr_return_loan(99, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(2, CURRENT_DATE - 60);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

-- Trigger test: updating another column creates no audit row
UPDATE loans SET borrower_name = borrower_name WHERE loan_id = 3;
SELECT count(*) AS audit_rows FROM loan_audit;   -- still 2

/* ===================== (e) View ===================== */
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title AS book_title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans ORDER BY loan_id;   -- loans 1, 4, 5

/* ===================== (f) Index ===================== */
-- Justification: the search only ever wants ONE book's loans that are still unreturned.
-- A PARTIAL index on book_id restricted to returned_on IS NULL is small (closed loans are
-- not stored in it) and exactly matches the query predicate.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

/* ===================== (g) Scheduled job ===================== */
-- Assumption: "overdue_count" counts loans unreturned as of p_as_of that are past their due date
-- (due_on < p_as_of); total_fine is the sum of their fines on that date.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(l.loan_id, p_as_of)), 0)
    FROM loans l
    WHERE l.borrowed_on <= p_as_of
      AND (l.returned_on IS NULL OR l.returned_on > p_as_of)   -- still unreturned as of that date
      AND l.due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE                        -- same date is replaced on rerun
        SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- Every day at 00:10 (pg_cron time zone) for CURRENT_DATE.
SELECT cron.schedule('q3_refresh_overdue_daily', '10 0 * * *',
                     $$CALL q3_library.pr_refresh_overdue(CURRENT_DATE)$$);

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun replaces, never duplicates
SELECT * FROM overdue_summary;           -- expected: count 3, total 46
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q3_refresh_overdue_daily';
