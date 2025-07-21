import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { CurrentPageReference } from 'lightning/navigation';
import getRecords from '@salesforce/apex/J_FAD_RecordDisplayController.getRecords';
import getConfig from '@salesforce/apex/J_FAD_RecordDisplayController.getConfig';
import cleanupQueryLocatorCache from '@salesforce/apex/J_FAD_RecordDisplayController.cleanupQueryLocatorCache';

export default class RecordListView extends NavigationMixin(LightningElement) {
    @track records = [];
    @track columns = [];
    @track error;
    @track isLoading = false;
    @track isLoadingMore = false;
    @track searchTerm = '';
    @track sortField = '';
    @track sortDirection = 'asc';
    @track config = {};
    @track listTitle = 'Records';
    @track displayedRecords = [];
    @track lastUpdateTime;
    @track queryLocatorId;
    @track currentPageReference;
    recordIdFromUrl;
    relatedObjectApiName;
    pageSize = 20;
    currentOffset = 0;
    hasMoreRecords = true;
    loadingType = 'infiniteScroll';
    expandedCardIds = new Set();
    configName = 'Pharmacy'; // Default fallback
    scrollThreshold = 100;
    isScrollLoading = false;
    @track isDropdownOpen = false;
    searchTimeout; // Added for debouncing search
    // Store scroll position
    scrollPosition = 0;
    containerHeight = 0;

    toggleDropdown() {
        this.isDropdownOpen = !this.isDropdownOpen;
    }

    connectedCallback() {
        this.isMobile = window.innerWidth <= 768;
        this.getCurrentPageReference();
    }

    getCurrentPageReference() {
        const pageRef = this[NavigationMixin.GenerateUrl]({
            type: 'standard__webPage',
            attributes: {
                url: window.location.href
            }
        });
        this.extractConfigNameFromUrl();
        this.loadConfig();
    }

    extractConfigNameFromUrl() {
        try {
            const url = window.location.href;
            const urlParts = url.split('/');
            console.log('Current URL:', url);

            // Example: /s/relatedlistview/001O4000014PKGsIAO/Contact
            if (urlParts.length >= 5) {
                this.recordIdFromUrl = urlParts[urlParts.length - 2]; // "001O4000014PKGsIAO"
                this.configName = urlParts[urlParts.length - 1];      // "Contact"
            } else {
                this.configName = 'Pharmacy';
                this.recordIdFromUrl = null;
            }

            console.log('Extracted recordId:', this.recordIdFromUrl);
            console.log('Config name set to:', this.configName);
        } catch (error) {
            console.error('Error extracting config name and recordId from URL:', error);
            this.configName = 'Pharmacy';
            this.recordIdFromUrl = null;
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
            
            // Parse sortBy from config to extract multiple fields
            this.parseSortByFromConfig();
            
            this.setupColumns();
            this.loadRecords(true);
        } catch (error) {
            console.error('Error loading config:', error);
            this.error = error.body?.message || `Error loading configuration for ${this.configName}`;
            this.config = {};
            this.columns = [];
            this.listTitle = 'Records';
        }
    }

    parseSortByFromConfig() {
        if (this.config.sortBy) {
            // Parse "Name ASC, Site ASC" format
            const sortParts = this.config.sortBy.split(',');
            if (sortParts.length > 0) {
                const firstSort = sortParts[0].trim().split(' ');
                this.sortField = firstSort[0];
                this.sortDirection = firstSort.length > 1 ? firstSort[1].toLowerCase() : 'asc';
            }
        }
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

            const sortBy = this.sortField ? `${this.sortField} ${this.sortDirection.toUpperCase()}` : this.config.sortBy;
            const result = await getRecords({
                configName: this.configName,
                pageSize: this.pageSize,
                offset: this.currentOffset,
                searchTerm: this.searchTerm,
                sortBy: sortBy,
                queryLocatorId: this.queryLocatorId,
                recordId: this.recordIdFromUrl 
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

    setupColumns() {
        if (this.config.fields && this.config.fields.length > 0) {
            const columns = [];
            const isAccountOrContact = this.config.objectApiName === 'Account' || this.config.objectApiName === 'Contact';
            
            const sortableFieldsFromConfig = this.getSortableFieldsFromConfig();

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
                    const isSortable = sortableFieldsFromConfig.includes(fieldConfig);
                    columns.push({
                        label: this.formatLabel(fieldConfig),
                        fieldName: fieldConfig,
                        sortable: isSortable,
                        isLink: this.isLinkField(fieldConfig),
                        type: 'text',
                        sortIcon: this.getSortIconForField(fieldConfig)
                    });
                } else if (typeof fieldConfig === 'object' && fieldConfig.fieldName) {
                    if (isAccountOrContact && (fieldConfig.fieldName === 'FirstName' || fieldConfig.fieldName === 'LastName' || fieldConfig.fieldName === 'Name')) {
                        return;
                    }
                    const isSortableFromConfig = sortableFieldsFromConfig.includes(fieldConfig.fieldName);
                    const isSortable = fieldConfig.sortable !== false && (fieldConfig.sortable === true || isSortableFromConfig);
                    columns.push({
                        label: fieldConfig.label || this.formatLabel(fieldConfig.fieldName),
                        fieldName: fieldConfig.fieldName,
                        sortable: isSortable,
                        isLink: fieldConfig.isLink || false,
                        type: fieldConfig.type || 'text',
                        sortIcon: this.getSortIconForField(fieldConfig.fieldName)
                    });
                } else if (typeof fieldConfig === 'object' && fieldConfig.sectionLabel && fieldConfig.fields) {
                    fieldConfig.fields.forEach(nestedField => {
                        if (typeof nestedField === 'object' && nestedField.fieldName) {
                            if (isAccountOrContact && (nestedField.fieldName === 'FirstName' || nestedField.fieldName === 'LastName' || nestedField.fieldName === 'Name')) {
                                return;
                            }
                            const isSortableFromConfig = sortableFieldsFromConfig.includes(nestedField.fieldName);
                            const isSortable = nestedField.sortable !== false && (nestedField.sortable === true || isSortableFromConfig);
                            columns.push({
                                label: nestedField.label || this.formatLabel(nestedField.fieldName),
                                fieldName: nestedField.fieldName,
                                sortable: isSortable,
                                isLink: nestedField.isLink || false,
                                type: nestedField.type || 'text',
                                sortIcon: this.getSortIconForField(nestedField.fieldName)
                            });
                        }
                    });
                }
            });

            this.columns = columns.filter(col => col && col.fieldName);
        }
    }

    getSortableFieldsFromConfig() {
        const sortableFields = [];
        if (this.config.sortBy) {
            const sortParts = this.config.sortBy.split(',');
            sortParts.forEach(part => {
                const fieldName = part.trim().split(' ')[0];
                if (fieldName && !sortableFields.includes(fieldName)) {
                    sortableFields.push(fieldName);
                }
            });
        }
        return sortableFields;
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

    handleCreateRecord() {
        if (!this.config || !this.config.objectApiName) {
            this.showToast('Error', 'Configuration missing objectApiName.', 'error');
            return;
        }

        let createDefaults = {
            apiName: this.config.objectApiName
        };

        if (this.config.recordTypeId) {
            createDefaults.recordTypeId = this.config.recordTypeId;
        }

        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: createDefaults.apiName,
                actionName: 'new'
            },
            state: {
                recordTypeId: createDefaults.recordTypeId
            }
        });
    }

    async getRecordTypeIdAndNavigate(recordTypeDeveloperName, navAttributes) {
        try {
            const refreshedConfig = await getConfig({ configName: this.configName });
            if (refreshedConfig.recordTypeId) {
                navAttributes.attributes.recordTypeId = refreshedConfig.recordTypeId;
                console.log('Found recordTypeId after refresh:', refreshedConfig.recordTypeId);
            } else {
                console.warn('RecordTypeId still not found after config refresh for:', this.configName);
            }

            this[NavigationMixin.Navigate](navAttributes);
        } catch (error) {
            console.error('Error getting record type ID:', error);
            this[NavigationMixin.Navigate](navAttributes);
        }
    }

    handleSort(event) {
        const fieldName = event.currentTarget.dataset.field;
        const column = this.columns.find(col => col.fieldName === fieldName);
        if (!column || !column.sortable) {
            console.warn('Field is not sortable:', fieldName);
            return;
        }
        
        if (this.sortField === fieldName) {
            this.sortDirection = this.sortDirection === 'asc' ? 'desc' : 'asc';
        } else {
            this.sortField = fieldName;
            this.sortDirection = 'asc';
        }
        
        this.columns = this.columns.map(col => ({
            ...col,
            sortIcon: this.getSortIconForField(col.fieldName)
        }));
        
        this.queryLocatorId = null;
        this.expandedCardIds.clear();
        this.loadRecords(true);
    }

    handleRefresh() {
        this.expandedCardIds.clear();
        this.queryLocatorId = null;
        this.loadRecords(true);
        this.showToast('Success', 'Records refreshed successfully', 'success');
    }

    handleRowClick(event) {
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

    eNewRecord() {
        try {
            if (!this.config.objectApiName) {
                throw new Error('Object API Name is not defined in the configuration.');
            }

            const navAttributes = {
                type: 'standard__objectPage',
                attributes: {
                    objectApiName: this.config.objectApiName,
                    actionName: 'new'
                }
            };

            if (this.config.recordTypeId) {
                navAttributes.attributes.recordTypeId = this.config.recordTypeId;
            }

            this[NavigationMixin.Navigate](navAttributes);
        } catch (error) {
            console.error('Error navigating to create record page:', error);
            this.showToast('Error', 'Failed to open create record page.', 'error');
        }
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

    getSortIconForField(fieldName) {
        if (this.sortField === fieldName) {
            return this.sortDirection === 'asc' ? 'utility:arrowup' : 'utility:arrowdown';
        }
        return 'utility:arrowdown';
    }
}