CREATE OR REPLACE PACKAGE pricing_notification_pkg AS
    PROCEDURE send_price_update(
        p_pool_id IN VARCHAR2,
        p_market_value IN NUMBER,
        p_yield_rate IN NUMBER
    );
END pricing_notification_pkg;
/