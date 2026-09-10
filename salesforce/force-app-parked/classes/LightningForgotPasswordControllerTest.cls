@IsTest
public with sharing class LightningForgotPasswordControllerTest {

 /* Verifies that ForgotPasswordController handles invalid usernames appropriately */
 @IsTest
 static void testLightningForgotPasswordControllerInvalidUserName() {
  System.assertEquals(LightningForgotPasswordController.forgotPassword('fakeUser', 'http://a.com'), Label.Site.invalid_email);
  System.assertEquals(LightningForgotPasswordController.forgotPassword(null, 'http://a.com'), Label.Site.invalid_email);
  System.assertEquals(LightningForgotPasswordController.forgotPassword('a', '/home/home.jsp'), Label.Site.invalid_email);
 }

 /* Verifies that a null/blank checkEmailRef url is rejected by the same-site
    redirect guard (returns the invalid-email label) instead of surfacing the
    raw "Argument 1 cannot be null" PageReference exception it used to. */
 @IsTest
 static void testLightningForgotPasswordControllerWithNullCheckEmailRef() {
  System.assertEquals(Label.Site.invalid_email, LightningForgotPasswordController.forgotPassword('a', null));
  System.assertEquals(Label.Site.invalid_email, LightningForgotPasswordController.forgotPassword('a@salesforce.com', null));
  // External / protocol-relative targets are rejected the same way (open-redirect guard).
  System.assertEquals(Label.Site.invalid_email, LightningForgotPasswordController.forgotPassword('a', 'https://evil.example'));
  System.assertEquals(Label.Site.invalid_email, LightningForgotPasswordController.forgotPassword('a', '//evil.example'));
 }

 /* Verifies that LightningForgotPasswordController object is instantiated correctly. */
 @IsTest
 static void LightningForgotPasswordControllerInstantiation() {
  LightningForgotPasswordController controller = new LightningForgotPasswordController();
  System.assertNotEquals(controller, null);
 }
}