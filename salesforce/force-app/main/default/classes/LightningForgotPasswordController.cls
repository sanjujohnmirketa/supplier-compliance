global class LightningForgotPasswordController {

    public LightningForgotPasswordController() {

    }

    @AuraEnabled
    public static String forgotPassword(String username, String checkEmailUrl) {
        try {
            Site.forgotPassword(username);
            // checkEmailUrl is caller-supplied — only allow a same-site relative
            // path (open-redirect otherwise: an absolute/external URL here would
            // send the user off-site after a real Salesforce action).
            if (String.isBlank(checkEmailUrl) || !checkEmailUrl.startsWith('/') || checkEmailUrl.startsWith('//')) {
                return Label.Site.invalid_email;
            }
            ApexPages.PageReference checkEmailRef = new PageReference(checkEmailUrl);
            if(!Site.isValidUsername(username)) {
                return Label.Site.invalid_email;
            }
            aura.redirect(checkEmailRef);
            return null;
        }
        catch (Exception ex) {
            return ex.getMessage();
        }
    }

    @AuraEnabled
    global static String setExperienceId(String expId) {    
        // Return null if there is no error, else it will return the error message 
        try {
            if (expId != null) {
                Site.setExperienceId(expId);               
            }
            return null; 
        } catch (Exception ex) {
            return ex.getMessage();            
        }        
    } 
}