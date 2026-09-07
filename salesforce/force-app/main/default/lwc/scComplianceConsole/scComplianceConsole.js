import { LightningElement, track } from 'lwc';
import complianceLogo from '@salesforce/resourceUrl/complianceLogo';

export default class ScComplianceConsole extends LightningElement {

    logoUrl = complianceLogo;

    @track persona = 'procurement';   // 'procurement' | 'analyst'

    get isProcurement() { return this.persona === 'procurement'; }
    get isAnalyst() { return this.persona === 'analyst'; }

    get procTabClass() {
        return this.persona === 'procurement' ? 'cc-tab active' : 'cc-tab';
    }
    get analystTabClass() {
        return this.persona === 'analyst' ? 'cc-tab active' : 'cc-tab';
    }

    handlePersona(event) {
        const p = event.currentTarget.dataset.persona;
        if (p && p !== this.persona) {
            this.persona = p;
        }
    }
}