import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import getRecords from '@salesforce/apex/J_FAD_RecordDisplayController.getRecords';
import getConfig from '@salesforce/apex/J_FAD_RecordDisplayController.getConfig';
import cleanupQueryLocatorCache from '@salesforce/apex/J_FAD_RecordDisplayController.cleanupQueryLocatorCache';

export default class RecordListView extends NavigationMixin(LightningElement) {
    @track records = [];
    @track parentRecordId = '';
    @track relatedObjectApiName = '';
    @track isRelatedListView = false;
    @track columns = [];
    @track error;
    @track isLoading = false;
    @track isLoadingMore = false;
    @track searchTerm = '';
    @track sortFields = []; // Array of { fieldName, direction }
    @track config = {};
    @track listTitle = 'Records';
    @track displayedRecords = [];
    @track lastUpdateTime;
    @track queryLocatorId;

    pageSize = 20;
    currentOffset = 0;
    hasMoreRecords = true;
    loadingType = 'infiniteScroll';
    expandedCardIds = new Set();
    configName = 'HCO'; // Updated to match your MDT Label
    scrollThreshold = 100;
    isScrollLoading = false;

    connectedCallback() {
        this.getCurrentPageReference();
    }

    getCurrentPageReference() {
        const pageRef = this[NavigationMixin.GenerateUrl]({
            type: 'standard__webPage',
            attributes: { url: window.location.href }
        });
        this.extractConfigNameFromUrl();
        this.loadConfig();
    }

    extractConfigNameFromUrl() {
        try {
            const url = window.location.href;
            console.log('Current URL:', url);
            const urlParts = url.split('/');
            const isRelatedList = urlParts.some(part => part === 'relatedlist');

            if (isRelatedList) {
                const recordIdIndex = urlParts.indexOf('relatedlist') + 1;
                const relatedObjectIndex = recordIdIndex + 1;

                this.parentRecordId = urlParts[recordIdIndex] || '';
                this.relatedObjectApiName = urlParts[relatedObjectIndex]?.split('?')[0] || '';
                this.isRelatedListView = String.isNotBlank(this.parentRecordId) && String.isNotBlank(this.relatedObjectApiName);

                if (this.isRelatedListView) {
                    this.configName = this.relatedObjectApiName;
                    console.log('Related List View - Parent Record ID:', this.parentRecordId);
                    console.log('Related List View - Related Object:', this.relatedObjectApiName);
                    console.log('Config name set to:', this.configName);
                } else {
                    this.configName = 'HCO'; // Updated to match your MDT Label
                    this.isRelatedListView = false;
                    console.log('Missing recordId or relatedObjectApiName, using default config:', this.configName);
                }
            } else {
                const pageName = urlParts[urlParts.length - 1].split('?')[0];
                this.configName = pageName && pageName !== 's' ? pageName : 'HCO'; // Updated to match your MDT Label
                this.isRelatedListView = false;
                console.log('Default List View - Config name set to:', this.configName);
            }
        } catch (error) {
            console.error('Error extracting config name from URL:', error);
            this.configName = 'HCO'; // Updated to match your MDT Label
            this.isRelatedListView = false;
        }
    }

    renderedCallback() {
        this.attachScrollListeners();
    }

    disconnectedCallback() {
        this.removeScrollListeners();
        if (this.queryLocatorId) {
            cleanupQueryLocatorCache()
                .catch(error => console.warn('Could not cleanup QueryLocator cache:', error));
        }
    }

    attachScrollListeners() {
        const tableContainer = this.template.querySelector('.table-container');
        if (tableContainer && !tableContainer.hasScrollListener) {
            tableContainer.addEventListener('scroll', this.handleScroll.bind(this));
            tableContainer.hasScrollListener = true;
        }
        const mobileContainer = this.template.querySelector('.mobile-card-container');
        if (mobileContainer && !mobileContainer.hasScrollListener) {
            mobileContainer.addEventListener('scroll', this.handleScroll.bind(this));
            mobileContainer.hasScrollListener = true;
        }
    }

    removeScrollListeners() {
        const tableContainer = this.template.querySelector('.table-container');
        if (tableContainer) {
            tableContainer.removeEventListener('scroll', this.handleScroll.bind(this));
            tableContainer.hasScrollListener = false;
        }
        const mobileContainer = this.template.querySelector('.mobile-card-container');
        if (mobileContainer) {
            mobileContainer.removeEventListener('scroll', this.handleScroll.bind(this));
            mobileContainer.hasScrollListener = false;
        }
    }

    async loadConfig() {
        try {
            console.log('Loading config with name:', this.configName);
            this.config = await getConfig({ configName: this.configName });
            this.listTitle = this.config.listTitle || 
                (this.config.recordType ? `${this.config.recordType} ${this.config.objectApiName}s` : `${this.config.objectApiName}s`);
            this.pageSize = this.config.pageSize || 20;
            this.loadingType = this.config.loadingType || 'infiniteScroll';

            // Initialize sortFields from config.sortBy
            this.sortFields = this.parseSortBy(this.config.sortBy || 'Name ASC');
            this.setupColumns();
            await this.loadRecords(true); // Ensure records load after columns are set
        } catch (error) {
            console.error('Error loading config:', error);
            this.error = error.body?.message || `Error loading configuration for ${this.configName}`;
            this.config = {};
            this.columns = [];
            this.listTitle = 'Records';
        }
    }

    parseSortBy(sortBy) {
        if (!sortBy) return [];
        return sortBy.split(',').map(sortPart => {
            const [fieldName, direction = 'ASC'] = sortPart.trim().split(/\s+/);
            return {
                fieldName: fieldName.trim(),
                direction: direction.toLowerCase() === 'desc' ? 'desc' : 'asc'
            };
        });
    }

    setupColumns() {
        if (this.config.fields && this.config.fields.length > 0) {
            const columns = [];
            const isAccountOrContact = this.config.objectApiName === 'Account' || this.config.objectApiName === 'Contact';

            if (isAccountOrContact) {
                columns.push({
                    label: 'Name',
                    fieldName: 'Name',
                    sortable: true,
                    isLink: true,
                    type: 'text',
                    sortIcon: this.getSortIconForField('Name')
                });
            }

            this.config.fields.forEach(fieldConfig => {
                if (typeof fieldConfig === 'string') {
                    if (isAccountOrContact && (fieldConfig === 'FirstName' || fieldConfig === 'LastName' || fieldConfig === 'Name')) {
                        return;
                    }
                    columns.push({
                        label: this.formatLabel(fieldConfig),
                        fieldName: fieldConfig,
                        sortable: true,
                        isLink: this.isLinkField(fieldConfig),
                        type: 'text',
                        sortIcon: this.getSortIconForField(fieldConfig)
                    });
                } else if (typeof fieldConfig === 'object' && fieldConfig.fieldName) {
                    if (isAccountOrContact && (fieldConfig.fieldName === 'FirstName' || fieldConfig.fieldName === 'LastName' || fieldConfig.fieldName === 'Name')) {
                        return;
                    }
                    columns.push({
                        label: fieldConfig.label || this.formatLabel(fieldConfig.fieldName),
                        fieldName: fieldConfig.fieldName,
                        sortable: fieldConfig.sortable !== false,
                        isLink: fieldConfig.isLink || false,
                        type: fieldConfig.type || 'text',
                        sortIcon: this.getSortIconForField(fieldConfig.fieldName)
                    });
                }
            });

            this.columns = columns.filter(col => col && col.fieldName);
            console.log('Columns with sortIcons:', JSON.stringify(this.columns));
        }
    }

    handleSort(event) {
        const fieldName = event.currentTarget.dataset.field;
        let sortFields = [...this.sortFields];
        const existingSortIndex = sortFields.findIndex(sf => sf.fieldName === fieldName);

        // Check if the field is sortable
        const column = this.columns.find(col => col.fieldName === fieldName);
        if (!column || !column.sortable) {
            console.log('Field is not sortable:', fieldName);
            return;
        }

        if (existingSortIndex >= 0) {
            sortFields[existingSortIndex].direction = sortFields[existingSortIndex].direction === 'asc' ? 'desc' : 'asc';
        } else {
            const defaultSort = this.parseSortBy(this.config.sortBy || 'Name ASC').find(sf => sf.fieldName === fieldName);
            const newDirection = defaultSort ? (defaultSort.direction === 'asc' ? 'desc' : 'asc') : 'asc'; // Default to 'asc' for new fields
            sortFields.push({ fieldName, direction: newDirection });
        }

        // Keep only unique fields and maintain order
        sortFields = sortFields.filter((sf, index, self) => 
            self.findIndex(s => s.fieldName === sf.fieldName) === index
        );

        this.sortFields = sortFields;

        // Update column sort icons immediately
        this.columns = this.columns.map(col => ({
            ...col,
            sortIcon: this.getSortIconForField(col.fieldName)
        }));

        console.log('Updated sortFields:', JSON.stringify(this.sortFields));

        this.queryLocatorId = null;
        this.expandedCardIds.clear();
        this.loadRecords(true);
    }

    async loadRecords(reset = false) {
        if (!this.hasMoreRecords && !reset) return;
        if (this.isScrollLoading && !reset) return;

        try {
            if (reset) {
                this.isLoading = true;
                this.currentOffset = 0;
                this.records = [];
                this.displayedRecords = [];
                this.queryLocatorId = null;
                this.hasMoreRecords = true;
                this.isScrollLoading = false;
            } else {
                this.isLoadingMore = true;
                this.isScrollLoading = true;
            }
            this.error = undefined;

            const result = await getRecords({
                configName: this.configName,
                pageSize: this.pageSize,
                offset: this.currentOffset,
                searchTerm: this.searchTerm,
                sortFields: this.sortFields,
                queryLocatorId: this.queryLocatorId,
                parentRecordId: this.parentRecordId,
                relatedObjectApiName: this.relatedObjectApiName
            });

            this.queryLocatorId = result.queryLocatorId;

            const mappedRecords = result.records.map((record, index) => {
                const mappedRecord = {
                    Id: record.Id,
                    key: `${record.Id}_${this.currentOffset + index}`,
                    rowNumber: this.currentOffset + index + 1,
                    cells: []
                };

                if (this.columns && this.columns.length > 0) {
                    this.columns.forEach(column => {
                        let fieldValue = this.getFieldValue(record, column.fieldName);
                        if (column.fieldName === 'Name' && (this.config.objectApiName === 'Account' || this.config.objectApiName === 'Contact')) {
                            const nameValue = this.getFieldValue(record, 'Name') || '';
                            if (!nameValue) {
                                const firstName = this.getFieldValue(record, 'FirstName') || '';
                                const lastName = this.getFieldValue(record, 'LastName') || '';
                                fieldValue = firstName && lastName ? `${firstName} ${lastName}` : firstName || lastName || nameValue;
                            } else {
                                fieldValue = nameValue;
                            }
                        }
                        mappedRecord.cells.push({
                            fieldName: column.fieldName,
                            label: column.label,
                            value: fieldValue,
                            isLink: column.isLink,
                            displayValue: this.formatDisplayValue(fieldValue, column)
                        });
                    });
                }

                this.setupMobileFields(mappedRecord);
                return mappedRecord;
            });

            if (reset) {
                this.records = mappedRecords;
                this.displayedRecords = mappedRecords.map(record => ({
                    ...record,
                    isExpanded: this.expandedCardIds.has(record.Id)
                }));
            } else {
                this.records = [...this.records, ...mappedRecords];
                this.displayedRecords = [...this.displayedRecords, ...mappedRecords.map(record => ({
                    ...record,
                    isExpanded: this.expandedCardIds.has(record.Id)
                }))];
            }

            this.hasMoreRecords = result.hasMore;
            this.currentOffset += result.records.length;
            this.lastUpdateTime = new Date();
        } catch (error) {
            this.error = error.body?.message || 'Error fetching records';
            if (reset) {
                this.records = [];
                this.displayedRecords = [];
            }
            this.hasMoreRecords = false;
        } finally {
            this.isLoading = false;
            this.isLoadingMore = false;
            this.isScrollLoading = false;
        }
    }

    getSortIconForField(fieldName) {
        const sortField = this.sortFields.find(sf => sf.fieldName === fieldName);
        return sortField ? (sortField.direction === 'asc' ? 'utility:arrowup' : 'utility:arrowdown') : null;
    }

    setupMobileFields(record) {
        if (!record.cells || record.cells.length === 0) return;

        const primaryFieldIndex = record.cells.findIndex(cell => 
            cell.fieldName === 'Name' || 
            cell.fieldName.toLowerCase().includes('title') || 
            cell.fieldName.toLowerCase().includes('subject')
        );

        if (primaryFieldIndex >= 0) {
            record.primaryField = record.cells[primaryFieldIndex];
            record.allFields = record.cells.filter((cell, index) => index !== primaryFieldIndex);
        } else {
            record.primaryField = record.cells[0];
            record.allFields = record.cells.slice(1);
        }

        record.allFields = record.allFields.filter(cell => cell.value !== null && cell.value !== undefined && cell.value !== '');

        const visibleFieldsCount = this.config.visibleMobileFields || 2;
        record.visibleFields = (record.allFields || []).slice(0, visibleFieldsCount);
        record.hiddenFields = (record.allFields || []).slice(visibleFieldsCount);

        record.isExpandable = this.config.isExpandable || false;
        record.hasHiddenFields = record.hiddenFields.length > 0;
        record.showExpandButton = record.isExpandable && record.hasHiddenFields;

        const subtitleField = record.cells.find(cell =>
            cell.fieldName.toLowerCase().includes('id') ||
            cell.fieldName.toLowerCase().includes('number')
        );
        if (subtitleField && subtitleField.value) {
            record.subtitle = subtitleField.displayValue;
        }
    }

    handleSearch(event) {
        const newSearchTerm = event.target.value;
        if (this.searchTimeout) clearTimeout(this.searchTimeout);
        this.searchTimeout = setTimeout(() => {
            if (this.searchTerm !== newSearchTerm) {
                this.searchTerm = newSearchTerm;
                this.queryLocatorId = null;
                this.expandedCardIds.clear();
                this.loadRecords(true);
            }
        }, 500);
    }

    handleRefresh() {
        this.expandedCardIds.clear();
        this.queryLocatorId = null;
        this.loadRecords(true);
        this.showToast('Success', 'Records refreshed successfully', 'success');
    }

    handleRowClick(event) {
        if (window.getSelection && window.getSelection().toString()) {
            return;
        }
        
        if (event.detail > 1) {
            return;
        }

        const recordId = event.currentTarget.dataset.id;
        const fieldName = event.currentTarget.dataset.field;

        if (!fieldName || !this.columns || this.columns.length === 0) {
            console.warn('Field name or columns not available, proceeding with navigation');
            this[NavigationMixin.Navigate]({
                type: 'standard__webPage',
                attributes: {
                    url: `/frmportal/s/recorddetailpage?recordId=${recordId}`
                }
            });
            return;
        }

        const column = this.columns.find(col => col.fieldName === fieldName);
        if (column && column.isLink) {
            try {
                this[NavigationMixin.Navigate]({
                    type: 'standard__webPage',
                    attributes: {
                        url: `/frmportal/s/recorddetailpage?recordId=${recordId}`
                    }
                });
            } catch (error) {
                console.error('Navigation error:', error);
                this.showToast('Error', 'Failed to navigate to record page.', 'error');
            }
        } else {
            console.log('Field is not a link or column not found:', fieldName);
        }
    }

    handleCardExpand(event) {
        event.stopPropagation();
        const recordId = event.currentTarget.dataset.id;
        if (!this.config.isExpandable) return;
        if (this.expandedCardIds.has(recordId)) {
            this.expandedCardIds.delete(recordId);
        } else {
            this.expandedCardIds.add(recordId);
        }
        this.displayedRecords = this.displayedRecords.map(record => ({
            ...record,
            isExpanded: this.expandedCardIds.has(record.Id)
        }));
    }

    handleScroll(event) {
        const target = event.target;
        const scrollTop = target.scrollTop;
        const scrollHeight = target.scrollHeight;
        const clientHeight = target.clientHeight;
        if (scrollTop + clientHeight >= scrollHeight - this.scrollThreshold) {
            this.loadRecords(false);
        }
    }

    getFieldValue(record, fieldName) {
        if (!record || !fieldName) return '';
        try {
            if (fieldName.includes('.')) {
                const parts = fieldName.split('.');
                let value = record;
                for (const part of parts) {
                    value = value?.[part];
                    if (value === null || value === undefined) break;
                }
                return value != null ? String(value) : '';
            }
            return record[fieldName] != null ? String(record[fieldName]) : '';
        } catch (error) {
            return '';
        }
    }

    formatDisplayValue(value, column) {
        if (!value) return '';
        try {
            switch (column.type) {
                case 'currency': return this.formatCurrency(value);
                case 'date': return this.formatDate(value);
                case 'datetime': return this.formatDateTime(value);
                case 'percent': return this.formatPercent(value);
                case 'phone': return this.formatPhone(value);
                default: return value;
            }
        } catch (error) {
            return value;
        }
    }

    formatLabel(fieldName) {
        if (!fieldName) return '';
        return fieldName
            .replace(/([A-Z])/g, ' $1')
            .replace(/^./, str => str.toUpperCase())
            .replace(/_/g, ' ')
            .replace(/\b\w/g, l => l.toUpperCase());
    }

    isLinkField(fieldName) {
        return fieldName.toLowerCase().includes('name') ||
            fieldName.toLowerCase().includes('email') ||
            fieldName.toLowerCase().includes('url');
    }

    showToast(title, message, variant) {
        const evt = new ShowToastEvent({ title, message, variant });
        this.dispatchEvent(evt);
    }

    formatCurrency(value) {
        try {
            return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(value);
        } catch (error) {
            return value;
        }
    }

    formatDate(value) {
        try {
            return new Date(value).toLocaleDateString();
        } catch (error) {
            return value;
        }
    }

    formatDateTime(value) {
        try {
            return new Date(value).toLocaleString();
        } catch (error) {
            return value;
        }
    }

    formatPercent(value) {
        try {
            return `${parseFloat(value).toFixed(2)}%`;
        } catch (error) {
            return value;
        }
    }

    formatPhone(value) {
        try {
            const cleaned = value.replace(/\D/g, '');
            if (cleaned.length === 10) {
                return cleaned.replace(/(\d{3})(\d{3})(\d{4})/, '($1) $2-$3');
            }
            return value;
        } catch (error) {
            return value;
        }
    }

    get itemsDisplayText() {
        const totalShown = this.displayedRecords.length;
        const totalAvailable = this.config.totalCount || totalShown;
        return this.hasMoreRecords ? `${totalShown}+ items` : `${totalShown} items`;
    }

    get filteredRecords() {
        return this.displayedRecords;
    }

    get showInfiniteScrollLoader() {
        return this.isLoadingMore && this.hasMoreRecords;
    }
}