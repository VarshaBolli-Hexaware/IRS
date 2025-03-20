CREATE OR REPLACE PACKAGE BODY pricing_notification_pkg AS

    PROCEDURE send_price_update(
        p_pool_id IN VARCHAR2,
        p_market_value IN NUMBER,
        p_yield_rate IN NUMBER
    ) IS
    BEGIN
        -- Log the input parameters (for debugging or audit purposes)
        DBMS_OUTPUT.PUT_LINE('Pool ID: ' || p_pool_id);
        DBMS_OUTPUT.PUT_LINE('Market Value: ' || p_market_value);
        DBMS_OUTPUT.PUT_LINE('Yield Rate: ' || p_yield_rate);

        -- Example logic: Insert the values into a notification table
        INSERT INTO price_update_notifications (
            pool_id,
            market_value,
            yield_rate,
            notification_date
        ) VALUES (
            p_pool_id,
            p_market_value,
            p_yield_rate,
            SYSDATE
        );

        -- Commit the transaction
        COMMIT;

        -- Additional notification logic (e.g., sending an email or message) can be added here
        DBMS_OUTPUT.PUT_LINE('Price update notification sent successfully.');

    EXCEPTION
        WHEN OTHERS THEN
            -- Handle any exceptions that occur during execution
            DBMS_OUTPUT.PUT_LINE('An error occurred: ' || SQLERRM);
            ROLLBACK; -- Rollback the transaction in case of an error
    END send_price_update;

END pricing_notification_pkg;
