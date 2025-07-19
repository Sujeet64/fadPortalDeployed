/**
 * @description       : 
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 07-18-2025
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
/**
 * @description       : Controller for handling record display and search functionality in a list view with server-side sorting.
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 07-18-2025
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
 */
public with sharing class J_FAD_RecordDisplayController {
    
    public class RecordResponse {
        @AuraEnabled public List<SObject> records;
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Boolean hasMore;
        @AuraEnabled public String queryLocatorId;
    }

    private static Map<String, Database.QueryLocator> queryLocatorCache = new Map<String, Database.QueryLocator>();
    
    @AuraEnabled(cacheable=false)
    public static RecordResponse getRecords(String configName, Integer pageSize, Integer offset, String searchTerm, List<Map<String, String>> sortFields, String queryLocatorId, String parentRecordId, String relatedObjectApiName) {
        try {
            if (String.isBlank(configName)) {
                throw new AuraHandledException('Configuration name is required.');
            }

            List<J_FAD_Listview_RecordDisplayConfig__mdt> configList = [
                SELECT Display_Records__c
                FROM J_FAD_Listview_RecordDisplayConfig__mdt
                WHERE DeveloperName = :configName
                LIMIT 1
            ];

            if (configList.isEmpty()) {
                throw new AuraHandledException('Configuration not found: ' + configName);
            }

            J_FAD_Listview_RecordDisplayConfig__mdt config = configList[0];
            if (String.isBlank(config.Display_Records__c)) {
                throw new AuraHandledException('Configuration JSON is empty or invalid.');
            }

            Map<String, Object> configData = (Map<String, Object>) JSON.deserializeUntyped(config.Display_Records__c);
            String objectApiName = (String) configData.get('objectApiName');
            String recordType = (String) configData.get('recordType');
            Boolean isActive = (Boolean) configData.get('isActive');
            List<Object> fieldsConfig = (List<Object>) configData.get('fields');
            String configSortBy = (String) configData.get('sortBy');
            Integer configPageSize = configData.containsKey('pageSize') ? (Integer) configData.get('pageSize') : 20;

            pageSize = pageSize != null ? pageSize : configPageSize;
            offset = offset != null ? offset : 0;

            if (String.isBlank(objectApiName) || !isActive || fieldsConfig == null || fieldsConfig.isEmpty()) {
                throw new AuraHandledException('Invalid configuration: Missing object, fields, or inactive config.');
            }

            List<String> safeFields = buildSafeFields(objectApiName, fieldsConfig);
            if (objectApiName == 'Account' && !safeFields.contains('IsPersonAccount')) {
                safeFields.add('IsPersonAccount');
            }

            List<Map<String, Object>> searchableFields = buildSearchableFields(objectApiName, fieldsConfig);

            List<String> whereConditions = new List<String>();

            if (String.isNotBlank(parentRecordId) && String.isNotBlank(relatedObjectApiName)) {
                String relationshipField = getRelationshipField(objectApiName, relatedObjectApiName);
                if (String.isNotBlank(relationshipField)) {
                    whereConditions.add(relationshipField + ' = \'' + String.escapeSingleQuotes(parentRecordId) + '\'');
                } else {
                    throw new AuraHandledException('No relationship field found between ' + objectApiName + ' and ' + relatedObjectApiName);
                }
            }

            if (String.isNotBlank(recordType)) {
                whereConditions.add('RecordType.DeveloperName = \'' + String.escapeSingleQuotes(recordType) + '\'');
            }

            if (String.isNotBlank(searchTerm) && !searchableFields.isEmpty()) {
                List<String> personAccountSearchConditions = new List<String>();
                List<String> businessAccountSearchConditions = new List<String>();

                for (Map<String, Object> searchField : searchableFields) {
                    String fieldName = (String) searchField.get('fieldName');
                    Boolean isPersonAccountField = (Boolean) searchField.get('isPersonAccountField');

                    String condition = fieldName + ' LIKE :likePattern';

                    if (isPersonAccountField) {
                        personAccountSearchConditions.add(condition);
                    } else {
                        businessAccountSearchConditions.add(condition);
                    }
                }

                List<String> searchConditions = new List<String>();

                if (objectApiName == 'Account') {
                    if (!personAccountSearchConditions.isEmpty()) {
                        searchConditions.add('(IsPersonAccount = true AND (' + String.join(personAccountSearchConditions, ' OR ') + '))');
                    }
                    if (!businessAccountSearchConditions.isEmpty()) {
                        searchConditions.add('(IsPersonAccount = false AND (' + String.join(businessAccountSearchConditions, ' OR ') + '))');
                    }
                } else {
                    List<String> combined = new List<String>();
                    combined.addAll(personAccountSearchConditions);
                    combined.addAll(businessAccountSearchConditions);
                    if (!combined.isEmpty()) {
                        searchConditions.add('(' + String.join(combined, ' OR ') + ')');
                    }
                }

                if (!searchConditions.isEmpty()) {
                    whereConditions.add('(' + String.join(searchConditions, ' OR ') + ')');
                }
            }

            String whereClause = whereConditions.isEmpty() ? '' : ' WHERE ' + String.join(whereConditions, ' AND ');
            String likePattern = '%' + (String.isNotBlank(searchTerm) ? searchTerm : '') + '%';

            return getRecordsWithQueryLocator(objectApiName, safeFields, whereClause, sortFields, configSortBy, 
                                             pageSize, offset, queryLocatorId, likePattern, searchTerm, fieldsConfig);

        } catch (Exception e) {
            System.debug('Error in getRecords: ' + e.getMessage());
            System.debug('Stack Trace: ' + e.getStackTraceString());
            throw new AuraHandledException('Error fetching records: ' + e.getMessage());
        }
    }

    private static String getRelationshipField(String childObjectApiName, String parentObjectApiName) {
        try {
            System.debug('Finding relationship field for child: ' + childObjectApiName + ', parent: ' + parentObjectApiName);
            Schema.SObjectType childSObjectType = Schema.getGlobalDescribe().get(childObjectApiName);
            Map<String, Schema.SObjectField> fieldMap = childSObjectType.getDescribe().fields.getMap();
            
            for (String fieldName : fieldMap.keySet()) {
                Schema.SObjectField field = fieldMap.get(fieldName);
                Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
                
                if (fieldDescribe.getType() == Schema.DisplayType.REFERENCE) {
                    List<Schema.SObjectType> referenceTo = fieldDescribe.getReferenceTo();
                    if (!referenceTo.isEmpty() && referenceTo[0].getDescribe().getName() == parentObjectApiName) {
                        System.debug('Found relationship field: ' + fieldName);
                        return fieldName;
                    }
                }
            }
            System.debug('No relationship field found between ' + childObjectApiName + ' and ' + parentObjectApiName);
            return null;
        } catch (Exception e) {
            System.debug('Error finding relationship field: ' + e.getMessage());
            return null;
        }
    }

    private static RecordResponse getRecordsWithQueryLocator(String objectApiName, List<String> safeFields, 
                                                            String whereClause, List<Map<String, String>> sortFields, 
                                                            String configSortBy, Integer pageSize, Integer offset, 
                                                            String queryLocatorId, String likePattern, String searchTerm, 
                                                            List<Object> fieldsConfig) {

        String query = 'SELECT ' + String.join(safeFields, ', ') + ' FROM ' + objectApiName + whereClause;

        // Validate and apply sorting
        String finalSortBy = validateSortBy(sortFields, configSortBy, fieldsConfig, safeFields);
        if (String.isNotBlank(finalSortBy)) {
            query += ' ORDER BY ' + finalSortBy;
        }

        query += ' LIMIT ' + (pageSize + 1);
        query += ' OFFSET ' + offset;

        System.debug('Final Query: ' + query);

        try {
            List<SObject> allRecords = Database.queryWithBinds(
                query, 
                new Map<String, Object>{ 'likePattern' => likePattern, 'searchTerm' => searchTerm }, 
                AccessLevel.USER_MODE
            );
            Boolean hasMore = allRecords.size() > pageSize;
            List<SObject> records;

            if (hasMore) {
                records = new List<SObject>();
                for (Integer i = 0; i < pageSize; i++) {
                    records.add(allRecords[i]);
                }
            } else {
                records = allRecords;
            }

            Integer totalCount = getTotalRecordCount(objectApiName, whereClause, likePattern, searchTerm);

            RecordResponse response = new RecordResponse();
            response.records = records;
            response.totalCount = totalCount;
            response.hasMore = hasMore;
            response.queryLocatorId = null;

            return response;
        } catch (Exception e) {
            System.debug('Query execution failed: ' + e.getMessage());
            throw new AuraHandledException('Error executing query: ' + e.getMessage());
        }
    }

    private static String validateSortBy(List<Map<String, String>> sortFields, String configSortBy, List<Object> fieldsConfig, List<String> safeFields) {
        String defaultSortBy = String.isNotBlank(configSortBy) ? configSortBy : 'Name ASC';
        List<String> validatedSortFields = new List<String>();

        // Build a map of sortable fields from config
        Map<String, Boolean> sortableFieldsMap = new Map<String, Boolean>();
        for (Object fieldConfig : fieldsConfig) {
            if (fieldConfig instanceof Map<String, Object>) {
                Map<String, Object> fieldMap = (Map<String, Object>) fieldConfig;
                String fieldName = (String) fieldMap.get('fieldName');
                Boolean sortable = fieldMap.containsKey('sortable') ? (Boolean) fieldMap.get('sortable') : true;
                if (String.isNotBlank(fieldName)) {
                    sortableFieldsMap.put(fieldName.toLowerCase(), sortable);
                }
            }
        }

        // Validate client-provided sort fields
        if (sortFields != null && !sortFields.isEmpty()) {
            for (Map<String, String> sortField : sortFields) {
                String fieldName = sortField.get('fieldName');
                String direction = sortField.get('direction')?.toUpperCase();

                if (String.isBlank(fieldName) || String.isBlank(direction)) {
                    System.debug('Skipping invalid sort field: ' + fieldName + ', direction: ' + direction);
                    continue;
                }

                if (direction != 'ASC' && direction != 'DESC') {
                    direction = 'ASC';
                    System.debug('Invalid direction for field ' + fieldName + ', defaulting to ASC');
                }

                // Check if field is sortable and exists in safeFields
                Boolean isSortable = sortableFieldsMap.containsKey(fieldName.toLowerCase()) ? sortableFieldsMap.get(fieldName.toLowerCase()) : false;
                Boolean isValidField = safeFields.contains(fieldName) || fieldName.contains('.');

                if (isSortable && isValidField) {
                    validatedSortFields.add(fieldName + ' ' + direction);
                    System.debug('Validated sort field: ' + fieldName + ' ' + direction);
                } else {
                    System.debug('Rejected sort field: ' + fieldName + ' (not sortable or not in safeFields)');
                }
            }
        } else {
            // Use default sortBy from config if no sortFields provided
            validatedSortFields.add(defaultSortBy);
            System.debug('No sort fields provided, using default: ' + defaultSortBy);
        }

        String finalSortBy = String.join(validatedSortFields, ', ');
        System.debug('Final sortBy: ' + finalSortBy);
        return finalSortBy;
    }

    private static Integer getTotalRecordCount(String objectApiName, String whereClause, String likePattern, String searchTerm) {
        try {
            String countQuery = 'SELECT COUNT() FROM ' + objectApiName + whereClause;
            return Database.countQueryWithBinds(countQuery, 
                new Map<String, Object>{ 'likePattern' => likePattern, 'searchTerm' => searchTerm }, 
                AccessLevel.USER_MODE);
        } catch (Exception e) {
            System.debug('Count query failed: ' + e.getMessage());
            return 0;
        }
    }

    private static List<String> buildSafeFields(String objectApiName, List<Object> fieldsConfig) {
        Set<String> uniqueFields = new Set<String>();

        for (Object fieldConfig : fieldsConfig) {
            String fieldName = '';

            if (fieldConfig instanceof Map<String, Object>) {
                Map<String, Object> configMap = (Map<String, Object>) fieldConfig;
                if (configMap.containsKey('fieldName')) {
                    fieldName = (String) configMap.get('fieldName');
                }
            } else if (fieldConfig instanceof String) {
                fieldName = (String) fieldConfig;
            }

            if (String.isNotBlank(fieldName)) {
                uniqueFields.add(fieldName);
            }
        }

        uniqueFields.add('Id');
        System.debug('Built safeFields: ' + uniqueFields);
        return new List<String>(uniqueFields);
    }

    private static List<Map<String, Object>> buildSearchableFields(String objectApiName, List<Object> fieldsConfig) {
        Schema.SObjectType sObjectType = Schema.getGlobalDescribe().get(objectApiName);
        Map<String, Schema.SObjectField> fieldMap = sObjectType.getDescribe().fields.getMap();

        List<Map<String, Object>> searchableFields = new List<Map<String, Object>>();

        Set<String> personAccountFields = new Set<String>{
            'FirstName', 'LastName', 'PersonEmail', 'PersonHomePhone', 'PersonMailingStreet',
            'PersonMailingCity', 'PersonMailingState', 'PersonMailingCountry', 'PersonMailingPostalCode'
        };

        for (Object fieldConfig : fieldsConfig) {
            String fieldName = '';
            Boolean isSectionField = false;

            if (fieldConfig instanceof Map<String, Object>) {
                Map<String, Object> fieldMap2 = (Map<String, Object>) fieldConfig;
                if (fieldMap2.containsKey('fields')) {
                    List<Object> nestedFields = (List<Object>) fieldMap2.get('fields');
                    for (Object nestedField : nestedFields) {
                        if (nestedField instanceof Map<String, Object>) {
                            Map<String, Object> nestedFieldMap = (Map<String, Object>) nestedField;
                            fieldName = (String) nestedFieldMap.get('fieldName');
                            isSectionField = true;
                            processField(fieldName, objectApiName, fieldMap, searchableFields, personAccountFields);
                        }
                    }
                    continue;
                } else {
                    fieldName = (String) fieldMap2.get('fieldName');
                }
            } else if (fieldConfig instanceof String) {
                fieldName = (String) fieldConfig;
            }

            if (!isSectionField && String.isNotBlank(fieldName)) {
                processField(fieldName, objectApiName, fieldMap, searchableFields, personAccountFields);
            }
        }

        return searchableFields;
    }

    private static void processField(String fieldName, String objectApiName, Map<String, Schema.SObjectField> fieldMap, 
                                    List<Map<String, Object>> searchableFields, Set<String> personAccountFields) {
        if (String.isNotBlank(fieldName)) {
            Boolean isPersonAccountField = objectApiName == 'Account' && personAccountFields.contains(fieldName);

            if (fieldName.contains('.')) {
                if (fieldName.contains('Name') || fieldName.contains('DeveloperName')) {
                    searchableFields.add(new Map<String, Object>{
                        'fieldName' => fieldName,
                        'isPersonAccountField' => false
                    });
                }
            } else if (fieldMap.containsKey(fieldName)) {
                Schema.SObjectField field = fieldMap.get(fieldName);
                Schema.DescribeFieldResult describe = field.getDescribe();
                Schema.DisplayType fieldType = describe.getType();

                Boolean isTextType = fieldType == Schema.DisplayType.STRING ||
                                     fieldType == Schema.DisplayType.TEXTAREA ||
                                     fieldType == Schema.DisplayType.EMAIL ||
                                     fieldType == Schema.DisplayType.PHONE ||
                                     fieldType == Schema.DisplayType.URL ||
                                     fieldType == Schema.DisplayType.PICKLIST ||
                                     fieldType == Schema.DisplayType.MULTIPICKLIST;

                if (isTextType && describe.isFilterable()) {
                    searchableFields.add(new Map<String, Object>{
                        'fieldName' => fieldName,
                        'isPersonAccountField' => isPersonAccountField
                    });
                }
            }
        }
    }

    @AuraEnabled
    public static void cleanupQueryLocatorCache() {
        queryLocatorCache.clear();
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getConfig(String configName) {
        try {
            if (String.isBlank(configName)) {
                throw new AuraHandledException('Configuration name is required.');
            }

            List<J_FAD_Listview_RecordDisplayConfig__mdt> configList = [
                SELECT Display_Records__c
                FROM J_FAD_Listview_RecordDisplayConfig__mdt
                WHERE DeveloperName = :configName
                LIMIT 1
            ];

            if (configList.isEmpty()) {
                throw new AuraHandledException('Configuration not found: ' + configName);
            }

            J_FAD_Listview_RecordDisplayConfig__mdt config = configList[0];

            if (String.isBlank(config.Display_Records__c)) {
                throw new AuraHandledException('Configuration JSON is empty or invalid.');
            }

            Map<String, Object> configData = (Map<String, Object>) JSON.deserializeUntyped(config.Display_Records__c);
            return configData;

        } catch (Exception e) {
            System.debug('Error in getConfig: ' + e.getMessage());
            throw new AuraHandledException('Error fetching configuration: ' + e.getMessage());
        }
    }
}