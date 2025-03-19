CREATE OR REPLACE PACKAGE delinquency_processing_pkg AS
    -- Constants
    c_version CONSTANT VARCHAR2(10) := '1.0.0';
    
    -- Exception definitions
    e_processing_error EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_processing_error, -20001);
    
    -- Core procedures and functions
    PROCEDURE process_delinquencies;
    
    FUNCTION get_days_past_due(
        p_loan_id IN VARCHAR2
    ) RETURN NUMBER;
    
END delinquency_processing_pkg;
/
