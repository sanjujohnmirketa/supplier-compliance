import { LightningElement, api } from 'lwc';

export default class UploadFilesFlow extends LightningElement {

    @api recordId;
    @api uploadedFileIds = [];

    acceptedFormats = ['.pdf','.png','.jpg','.jpeg','.doc','.docx'];

    handleUploadFinished(event) {

        const uploadedFiles = event.detail.files;

        this.uploadedFileIds =
            uploadedFiles.map(file => file.documentId);
    }
}