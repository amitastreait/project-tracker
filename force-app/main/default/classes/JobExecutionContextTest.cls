/**
 * JobExecutionContextTest
 *
 * Verifies default initialization and the convenience accessor methods.
 * No org data needed.
 */
@IsTest
private class JobExecutionContextTest {

    @IsTest
    static void testDefaults() {
        JobExecutionContext ctx = new JobExecutionContext();

        System.assertEquals(1, ctx.attemptNumber, 'Default attempt should be 1');
        System.assertNotEquals(null, ctx.parameters,    'Parameters map must be initialized');
        System.assertNotEquals(null, ctx.sharedContext, 'SharedContext map must be initialized');
        System.assertEquals(0, ctx.parameters.size());
        System.assertEquals(0, ctx.sharedContext.size());
    }

    @IsTest
    static void testGetParameter_returnsValueWhenPresent() {
        JobExecutionContext ctx = new JobExecutionContext();
        ctx.parameters.put('lookbackHours', 48);

        Object result = ctx.getParameter('lookbackHours', 24);
        System.assertEquals(48, result);
    }

    @IsTest
    static void testGetParameter_returnsDefaultWhenMissing() {
        JobExecutionContext ctx = new JobExecutionContext();

        Object result = ctx.getParameter('missing', 99);
        System.assertEquals(99, result);
    }

    @IsTest
    static void testGetSharedValue_returnsValueWhenPresent() {
        JobExecutionContext ctx = new JobExecutionContext();
        ctx.sharedContext.put('accountsSyncedToday', 150);

        Object result = ctx.getSharedValue('accountsSyncedToday', 0);
        System.assertEquals(150, result);
    }

    @IsTest
    static void testGetSharedValue_returnsDefaultWhenMissing() {
        JobExecutionContext ctx = new JobExecutionContext();

        Object result = ctx.getSharedValue('notSet', 'fallback');
        System.assertEquals('fallback', result);
    }

    @IsTest
    static void testMapsAreMutable() {
        JobExecutionContext ctx = new JobExecutionContext();
        ctx.parameters.put('key1', 'val1');
        ctx.sharedContext.put('key2', 42);

        System.assertEquals('val1', ctx.parameters.get('key1'));
        System.assertEquals(42,     ctx.sharedContext.get('key2'));
    }
}
