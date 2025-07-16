/**
 * @description       : Controller for handling record display and search functionality in a list view.
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 07-16-2025
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
    public static RecordResponse getRecords(String configName, Integer pageSize, Integer offset, String searchTerm, String queryLocatorId) {
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
            
            if (String.isNotBlank(recordType)) {
                whereConditions.add('RecordType.DeveloperName = \'' + String.escapeSingleQuotes(recordType) + '\'');
            }

            if (String.isNotBlank(searchTerm) && !searchableFields.isEmpty()) {
                List<String> personAccountSearchConditions = new List<String>();
                List<String> businessAccountSearchConditions = new List<String>();
                for (Map<String, Object> searchField : searchableFields) {
                    String fieldName = (String) searchField.get('fieldName');
                    Boolean isEncrypted = (Boolean) searchField.get('isEncrypted');
                    Boolean isPersonAccountField = (Boolean) searchField.get('isPersonAccountField');
                    String condition = isEncrypted ? 
                        (fieldName + ' = :searchTerm') : 
                        (fieldName + ' LIKE :likePattern');
                    
                    if (isPersonAccountField) {
                        personAccountSearchConditions.add(condition);
                    } else {
                        businessAccountSearchConditions.add(condition);
                    }
                }

                List<String> searchConditions = new List<String>();
                if (!personAccountSearchConditions.isEmpty()) {
                    searchConditions.add('(IsPersonAccount = true AND (' + String.join(personAccountSearchConditions, ' OR ') + '))');
                }
                if (!businessAccountSearchConditions.isEmpty()) {
                    searchConditions.add('(IsPersonAccount = false AND (' + String.join(businessAccountSearchConditions, ' OR ') + '))');
                }
                if (!searchConditions.isEmpty()) {
                    whereConditions.add('(' + String.join(searchConditions, ' OR ') + ')');
                }
            }

            String whereClause = whereConditions.isEmpty() ? '' : ' WHERE ' + String.join(whereConditions, ' AND ');

            String likePattern = '%' + (String.isNotBlank(searchTerm) ? searchTerm : '') + '%';
            return getRecordsWithQueryLocator(objectApiName, safeFields, whereClause, pageSize, offset, queryLocatorId, likePattern, searchTerm);

        } catch (Exception e) {
            System.debug('Error in getRecords: ' + e.getMessage());
            System.debug('Stack Trace: ' + e.getStackTraceString());
            throw new AuraHandledException('Error fetching records: ' + e.getMessage());
        }
    }

    private static RecordResponse getRecordsWithQueryLocator(String objectApiName, List<String> safeFields, 
                                                           String whereClause, Integer pageSize, Integer offset, 
                                                           String queryLocatorId, String likePattern, String searchTerm) {
        
        String query = 'SELECT ' + String.join(safeFields, ', ') + ' FROM ' + objectApiName + whereClause;
        
        System.debug('QueryLocator Query: ' + query);
        
        Database.QueryLocator queryLocator;
        String currentLocatorId = queryLocatorId;
        
        if (String.isNotBlank(queryLocatorId) && queryLocatorCache.containsKey(queryLocatorId)) {
            queryLocator = queryLocatorCache.get(queryLocatorId);
        } else {
            queryLocator = Database.getQueryLocatorWithBinds(
                query, 
                new Map<String, Object>{ 'likePattern' => likePattern, 'searchTerm' => searchTerm }, 
                AccessLevel.USER_MODE
            );
            currentLocatorId = generateQueryLocatorId();
            queryLocatorCache.put(currentLocatorId, queryLocator);
        }

        Database.QueryLocatorIterator iterator = queryLocator.iterator();
        
        Integer skipCount = 0;
        while (iterator.hasNext() && skipCount < offset) {
            iterator.next();
            skipCount++;
        }
        
        List<SObject> records = new List<SObject>();
        Integer recordCount = 0;
        while (iterator.hasNext() && recordCount < pageSize) {
            records.add(iterator.next());
            recordCount++;
        }
        
        Integer totalCount = getTotalRecordCount(objectApiName, whereClause);
        
        RecordResponse response = new RecordResponse();
        response.records = records;
        response.totalCount = totalCount;
        response.hasMore = (offset + pageSize) < totalCount && iterator.hasNext();
        response.queryLocatorId = currentLocatorId;

        return response;
    }

    private static Integer getTotalRecordCount(String objectApiName, String whereClause) {
        try {
            String countQuery = 'SELECT COUNT() FROM ' + objectApiName + whereClause;
            return Database.countQuery(countQuery);
        } catch (Exception e) {
            System.debug('Count query failed: ' + e.getMessage());
            return 50000;
        }
    }

    private static String generateQueryLocatorId() {
        return 'QL_' + System.currentTimeMillis() + '_' + Math.round(Math.random() * 1000);
    }

    private static List<String> buildSafeFields(String objectApiName, List<Object> fieldsConfig) {
        Schema.SObjectType sObjectType = Schema.getGlobalDescribe().get(objectApiName);
        Map<String, Schema.SObjectField> fieldMap = sObjectType.getDescribe().fields.getMap();
        
        Set<String> uniqueFields = new Set<String>();
        
        for (Object fieldConfig : fieldsConfig) {
            String fieldName = '';
            if (fieldConfig instanceof Map<String, Object>) {
                Map<String, Object> fieldMap2 = (Map<String, Object>) fieldConfig;
                if (fieldMap2.containsKey('fields')) {
                    List<Object> nestedFields = (List<Object>) fieldMap2.get('fields');
                    for (Object nestedField : nestedFields) {
                        if (nestedField instanceof Map<String, Object>) {
                            fieldName = (String) ((Map<String, Object>) nestedField).get('fieldName');
                            if (String.isNotBlank(fieldName)) {
                                if (fieldName.contains('.')) {
                                    String[] parts = fieldName.split('\\.');
                                    if (parts.size() == 2) {
                                        String relationshipField = parts[0];
                                        if (relationshipField == 'RecordType' || relationshipField == 'Owner' ||
                                            relationshipField == 'CreatedBy' || relationshipField == 'LastModifiedBy') {
                                            uniqueFields.add(fieldName);
                                        }
                                    }
                                } else if (fieldMap.containsKey(fieldName)) {
                                    uniqueFields.add(fieldName);
                                }
                            }
                        }
                    }
                } else {
                    fieldName = (String) fieldMap2.get('fieldName');
                }
            } else if (fieldConfig instanceof String) {
                fieldName = (String) fieldConfig;
            }

            if (String.isNotBlank(fieldName) && !fieldName.contains('.')) {
                if (fieldMap.containsKey(fieldName)) {
                    uniqueFields.add(fieldName);
                }
            }
        }

        uniqueFields.add('Id');
        
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
                        'isEncrypted' => false,
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
                        'isEncrypted' => describe.isEncrypted(),
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