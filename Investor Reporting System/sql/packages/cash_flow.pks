CREATE OR REPLACE PACKAGE cash_flow_pkg AS
    -- Constants
    c_prepayment_multiplier CONSTANT NUMBER := 0.06;  -- PSA multiplier
    c_default_severity CONSTANT NUMBER := 0.35;       -- Default severity rate
    
    -- Types
    TYPE r_cash_flow IS RECORD (
        period NUMBER,
        scheduled_principal NUMBER,
        scheduled_interest NUMBER,
        prepayment NUMBER,
        default_amount NUMBER,
        net_cash_flow NUMBER
    );
    
    TYPE t_cash_flow_table IS TABLE OF r_cash_flow;
    
    -- Core procedures and functions
    FUNCTION project_cash_flows(
        p_pool_id IN VARCHAR2,
        p_projection_months IN NUMBER DEFAULT 360
    ) RETURN t_cash_flow_table PIPELINED;
    
    FUNCTION calculate_pool_duration(
        p_pool_id IN VARCHAR2,
        p_yield_rate IN NUMBER
    ) RETURN NUMBER;
    
    FUNCTION calculate_pool_convexity(
        p_pool_id IN VARCHAR2,
        p_yield_rate IN NUMBER,
        p_duration IN NUMBER
    ) RETURN NUMBER;
    
END cash_flow_pkg;
/