CREATE OR REPLACE PACKAGE BODY pool_valuation_pkg AS

    FUNCTION calculate_pool_metrics( 
        p_pool_id IN VARCHAR2 
    ) RETURN r_pool_valuation IS 
        v_valuation r_pool_valuation; 
        v_risk_metrics loan_risk_assessment_pkg.r_risk_metrics; 
        v_total_balance NUMBER := 0; 
        v_weighted_rate NUMBER := 0; 
        v_base_rate NUMBER; 
    BEGIN 
        -- Get pool details 
        SELECT pool_id, current_amount, weighted_rate 
        INTO v_valuation.pool_id, v_total_balance, v_base_rate 
        FROM pool_definition 
        WHERE pool_id = p_pool_id; 
        
        -- Calculate weighted average coupon (WAC) 
        SELECT SUM(l.current_balance * l.interest_rate) / SUM(l.current_balance) 
        INTO v_valuation.wac_rate 
        FROM loan_master l 
        JOIN pool_loan_xref x ON l.loan_id = x.loan_id 
        WHERE x.pool_id = p_pool_id 
        AND x.active_flag = 'Y'; 
        
        -- Get pool risk metrics 
        SELECT avg_risk_score / 100 
        INTO v_risk_metrics.risk_score 
        FROM pool_risk_metrics 
        WHERE pool_id = p_pool_id; 
        
        -- Calculate yield rate (WAC - servicing fee + risk premium) 
        v_valuation.yield_rate := v_valuation.wac_rate - 0.0025 +  -- 25 bps servicing fee 
            GREATEST( 
                c_min_yield_spread, 
                LEAST(c_max_yield_spread, v_risk_metrics.risk_score * 0.02) 
            ); 
        
        -- Calculate duration (simplified) 
        v_valuation.duration := cash_flow_pkg.calculate_pool_duration( 
            p_pool_id, 
            v_valuation.yield_rate 
        ); 
        
        -- Calculate convexity (simplified) 
        v_valuation.convexity := cash_flow_pkg.calculate_pool_convexity( 
            p_pool_id, 
            v_valuation.yield_rate, 
            v_valuation.duration 
        ); 
        
        -- Calculate market value using duration and convexity 
        v_valuation.market_value := v_total_balance * ( 
            1 + v_valuation.duration * (v_base_rate - v_valuation.yield_rate) + 
            0.5 * v_valuation.convexity * POWER(v_base_rate - v_valuation.yield_rate, 2) 
        ); 
        
        RETURN v_valuation; 
    EXCEPTION 
        WHEN OTHERS THEN 
            investor_reporting_pkg.log_exception( 
                p_pool_id, 
                NULL, 
                'POOL_METRICS_CALCULATION', 
                'HIGH', 
                'Error calculating pool metrics: ' SQLERRM 
            ); 
            RAISE; 
    END calculate_pool_metrics; 

    PROCEDURE update_pool_pricing( 
        p_pool_id IN VARCHAR2, 
        p_valuation IN r_pool_valuation 
    ) IS 
    BEGIN 
        -- Use MERGE to upsert pool pricing information
        MERGE INTO pool_pricing tgt 
        USING ( 
            SELECT  
                p_pool_id AS pool_id, 
                p_valuation.market_value AS market_value, 
                p_valuation.yield_rate AS yield_rate, 
                p_valuation.wac_rate AS wac_rate, 
                p_valuation.duration AS duration, 
                p_valuation.convexity AS convexity, 
                SYSDATE AS pricing_date, 
                USER AS modified_by 
            FROM dual 
        ) src 
        ON (tgt.pool_id = src.pool_id) 
        WHEN MATCHED THEN 
            UPDATE SET 
                tgt.market_value = src.market_value, 
                tgt.yield_rate = src.yield_rate, 
                tgt.wac_rate = src.wac_rate, 
                tgt.duration = src.duration, 
                tgt.convexity = src.convexity, 
                tgt.pricing_date = src.pricing_date, 
                tgt.modified_by = src.modified_by 
        WHEN NOT MATCHED THEN 
            INSERT ( 
                pool_id, market_value, yield_rate, wac_rate, duration, convexity, pricing_date, modified_by 
            ) VALUES ( 
                src.pool_id, src.market_value, src.yield_rate, src.wac_rate, src.duration, src.convexity, src.pricing_date, src.modified_by 
            ); 

        -- Notify pricing service 
        pricing_notification_pkg.send_price_update( 
            p_pool_id, 
            p_valuation.market_value, 
            p_valuation.yield_rate 
        ); 
        
        COMMIT; 
    EXCEPTION 
        WHEN OTHERS THEN 
            ROLLBACK; 
            investor_reporting_pkg.log_exception( 
                p_pool_id, 
                NULL, 
                'POOL_PRICING_UPDATE', 
                'HIGH', 
                'Error updating pool pricing: ' SQLERRM 
            ); 
            RAISE; 
    END update_pool_pricing; 

    PROCEDURE recalculate_pool_value( 
        p_pool_id IN VARCHAR2 
    ) IS 
        v_valuation r_pool_valuation; 
    BEGIN 
        -- Calculate new pool metrics 
        v_valuation := calculate_pool_metrics(p_pool_id); 
        
        -- Update pricing 
        update_pool_pricing(p_pool_id, v_valuation); 
        
        -- Update investor reporting 
        investor_reporting_pkg.calculate_pool_statistics( 
            p_pool_id, 
            SYSDATE 
        ); 
    EXCEPTION 
        WHEN OTHERS THEN 
            investor_reporting_pkg.log_exception( 
                p_pool_id, 
                NULL, 
                'POOL_VALUATION', 
                'HIGH', 
                'Error recalculating pool value: ' SQLERRM 
            ); 
            RAISE; 
    END recalculate_pool_value; 

END pool_valuation_pkg; 
/
