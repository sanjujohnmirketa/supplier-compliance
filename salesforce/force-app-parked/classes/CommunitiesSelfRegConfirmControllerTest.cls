/**
 * An apex page controller that takes the user to the right start page based on credentials or lack thereof
 */
@IsTest public with sharing class CommunitiesSelfRegConfirmControllerTest {
    @IsTest public static void testCommunitiesSelfRegConfirmController() {
        // Controller has no fields/logic — the only thing to verify is that
        // it constructs without throwing.
        CommunitiesSelfRegConfirmController controller = new CommunitiesSelfRegConfirmController();
        System.assertNotEquals(null, controller);
      }
}