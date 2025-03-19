CREATE OR REPLACE PACKAGE loan_servicing_pkg AS
    -- Constants
    c_min_payment_amount CONSTANT NUMBER := 0.01;
    c_max_late_fee_rate CONSTANT NUMBER := 0.05;  -- 5%
    c_grace_period_days CONSTANT NUMBER := 15;
    
    -- Types
    TYPE r_payment_allocation IS RECORD (
        principal_amount NUMBER,
        interest_amount NUMBER,
        escrow_amount NUMBER,
        late_fees NUMBER,
        other_fees NUMBER
    );
    
    TYPE r_loan_status_history IS RECORD (
        loan_id VARCHAR2(20),
        old_status VARCHAR2(20),
        new_status VARCHAR2(20),
        change_date DATE,
        reason_code VARCHAR2(10),
        comments VARCHAR2(1000)
    );
    
    -- Core procedures and functions
    FUNCTION calculate_payment_allocation(
        p_loan_id IN VARCHAR2,
        p_payment_amount IN NUMBER,
        p_payment_date IN DATE DEFAULT SYSDATE
    ) RETURN r_payment_allocation;
    
    PROCEDURE process_payment(
        p_loan_id IN VARCHAR2,
        p_payment_amount IN NUMBER,
        p_payment_date IN DATE DEFAULT SYSDATE,
        p_payment_type IN VARCHAR2 DEFAULT 'REGULAR'
    );
    
    PROCEDURE update_loan_status(
        p_loan_id IN VARCHAR2,
        p_new_status IN VARCHAR2,
        p_reason_code IN VARCHAR2,
        p_comments IN VARCHAR2 DEFAULT NULL
    );
    
    FUNCTION get_loan_history(
        p_loan_id IN VARCHAR2,
        p_start_date IN DATE,
        p_end_date IN DATE DEFAULT SYSDATE
    ) RETURN SYS_REFCURSOR;
    
    PROCEDURE recalculate_loan_metrics(
        p_loan_id IN VARCHAR2,
        p_force_update IN BOOLEAN DEFAULT FALSE
    );
    
END loan_servicing_pkg;
/