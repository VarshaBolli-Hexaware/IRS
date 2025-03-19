CREATE OR REPLACE PACKAGE loan_processing_pkg AS
    -- Constants for business rules
    c_max_loan_amount CONSTANT NUMBER := 5000000;
    c_min_interest_rate CONSTANT NUMBER := 0.001;
    c_max_interest_rate CONSTANT NUMBER := 0.25;
    
    -- Type definitions
    TYPE r_loan_details IS RECORD (
        loan_id loan_master.loan_id%TYPE,
        current_balance loan_master.current_balance%TYPE,
        interest_rate loan_master.interest_rate%TYPE,
        next_payment_date loan_master.next_payment_date%TYPE,
        status loan_master.status%TYPE
    );
    
    -- Public procedures and functions
    PROCEDURE register_new_loan (
        p_fannie_loan_number IN VARCHAR2,
        p_original_amount IN NUMBER,
        p_interest_rate IN NUMBER,
        p_term_months IN NUMBER,
        p_origination_date IN DATE,
        p_loan_id OUT NUMBER
    );
    
    PROCEDURE process_payment (
        p_loan_id IN NUMBER,
        p_payment_amount IN NUMBER,
        p_transaction_date IN DATE,
        p_transaction_id OUT NUMBER
    );
    
    FUNCTION calculate_next_payment_date (
        p_loan_id IN NUMBER,
        p_current_date IN DATE DEFAULT SYSDATE
    ) RETURN DATE;
    
    PROCEDURE update_loan_status (
        p_loan_id IN NUMBER,
        p_new_status IN VARCHAR2
    );
    
    FUNCTION get_loan_details (
        p_loan_id IN VARCHAR2
    ) RETURN r_loan_details;
    
END loan_processing_pkg;
/