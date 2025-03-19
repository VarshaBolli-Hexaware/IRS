CREATE OR REPLACE PACKAGE pool_valuation_pkg AS
    -- Constants
    c_min_yield_spread CONSTANT NUMBER := 0.0025;  -- 25 bps minimum spread
    c_max_yield_spread CONSTANT NUMBER := 0.05;    -- 500 bps maximum spread
    
    -- Types
    TYPE r_pool_valuation IS RECORD (
        pool_id pool_definition.pool_id%TYPE,
        market_value NUMBER,
        yield_rate NUMBER,
        wac_rate NUMBER,
        duration NUMBER,
        convexity NUMBER
    );
    
    -- Core procedures and functions
    PROCEDURE recalculate_pool_value(
        p_pool_id IN VARCHAR2
    );
    
    FUNCTION calculate_pool_metrics(
        p_pool_id IN VARCHAR2
    ) RETURN r_pool_valuation;
    
    PROCEDURE update_pool_pricing(
        p_pool_id IN VARCHAR2,
        p_valuation IN r_pool_valuation
    );
    
END pool_valuation_pkg;
/