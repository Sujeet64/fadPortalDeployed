/**
 * @description       : 
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 07-14-2025
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
public with sharing class J_FAD_RecordDisplayController {
    
    public class RecordResponse {
        @AuraEnabled public List<SObject> records;
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Boolean hasMore;
        @AuraEnabled public String queryLocatorId;
    }

    private static Map<String, Database.QueryLocator> queryLocatorCache = new Map<String, Database.QueryLocator>();
    
    @AuraEnabled(cacheable=false)
    public static RecordResponse getRecords(String configName, Integer pageSize, Integer offset, String searchTerm, String sortBy, String queryLocatorId) {
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
            List<String> searchableFields = buildSearchableFields(objectApiName, fieldsConfig);

            List<String> whereConditions = new List<String>();
            
            if (String.isNotBlank(recordType)) {
                whereConditions.add('RecordType.DeveloperName = \'' + String.escapeSingleQuotes(recordType) + '\'');
            }

            String likePattern = '%' + (String.isNotBlank(searchTerm) ? searchTerm : '') + '%';
            if (String.isNotBlank(searchTerm) && !searchableFields.isEmpty()) {
                List<String> searchConditions = new List<String>();
                for (String searchField : searchableFields) {
                    searchConditions.add(searchField + ' LIKE :likePattern');
                }
                whereConditions.add('(' + String.join(searchConditions, ' OR ') + ')');
            }

            String whereClause = whereConditions.isEmpty() ? '' : ' WHERE ' + String.join(whereConditions, ' AND ');

            return getRecordsWithQueryLocator(objectApiName, safeFields, whereClause, sortBy, configSortBy, 
                                            pageSize, offset, queryLocatorId, likePattern);

        } catch (Exception e) {
            System.debug('Error in getRecords: ' + e.getMessage());
            System.debug('Stack Trace: ' + e.getStackTraceString());
            throw new AuraHandledException('Error fetching records: ' + e.getMessage());
        }
    }

    private static RecordResponse getRecordsWithQueryLocator(String objectApiName, List<String> safeFields, 
                                                           String whereClause, String sortBy, String configSortBy,
                                                           Integer pageSize, Integer offset, String queryLocatorId, String likePattern) {
        
        String query = 'SELECT ' + String.join(safeFields, ', ') + ' FROM ' + objectApiName + whereClause;
        
        String finalSortBy = String.isNotBlank(sortBy) ? sortBy : (String.isNotBlank(configSortBy) ? configSortBy : 'Name ASC');
        if (String.isNotBlank(finalSortBy)) {
            String sortField = finalSortBy.split(' ')[0];
            if (safeFields.contains(sortField) || sortField.contains('.')) {
                //query += ' ORDER BY ' + finalSortBy;
            }
        }
        
        System.debug('QueryLocator Query: ' + query);
        
        Database.QueryLocator queryLocator;
        String currentLocatorId = queryLocatorId;
        
        if (String.isNotBlank(queryLocatorId) && queryLocatorCache.containsKey(queryLocatorId)) {
            queryLocator = queryLocatorCache.get(queryLocatorId);
        } else {
            queryLocator = Database.getQueryLocator(query);
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
            return 50000; // Return max estimate
        }
    }

    private static String generateQueryLocatorId() {
        return 'QL_' + System.currentTimeMillis() + '_' + Math.round(Math.random() * 1000);
    }

    private static List<String> buildSafeFields(String objectApiName, List<Object> fieldsConfig) {
        Schema.SObjectType sObjectType = Schema.getGlobalDescribe().get(objectApiName);
        Map<String, Schema.SObjectField> fieldMap = sObjectType.getDescribe().fields.getMap();
        
        List<String> safeFields = new List<String>();
        
        for (Object fieldConfig : fieldsConfig) {
            String fieldName = '';
            if (fieldConfig instanceof String) {
                fieldName = (String) fieldConfig;
            } else if (fieldConfig instanceof Map<String, Object>) {
                Map<String, Object> fieldMap2 = (Map<String, Object>) fieldConfig;
                fieldName = (String) fieldMap2.get('fieldName');
            }

            if (String.isNotBlank(fieldName)) {
                if (fieldName.contains('.')) {
                    String[] parts = fieldName.split('\\.');
                    if (parts.size() == 2) {
                        String relationshipField = parts[0];
                        if (relationshipField == 'RecordType' || relationshipField == 'Owner' ||
                            relationshipField == 'CreatedBy' || relationshipField == 'LastModifiedBy') {
                            safeFields.add(fieldName);
                        }
                    }
                } else if (fieldMap.containsKey(fieldName)) {
                    safeFields.add(fieldName);
                }
            }
        }

        if (!safeFields.contains('Id')) {
            safeFields.add('Id');
        }
        
        return safeFields;
    }

    private static List<String> buildSearchableFields(String objectApiName, List<Object> fieldsConfig) {
    Schema.SObjectType sObjectType = Schema.getGlobalDescribe().get(objectApiName);
    Map<String, Schema.SObjectField> fieldMap = sObjectType.getDescribe().fields.getMap();

    List<String> searchableFields = new List<String>();

    for (Object fieldConfig : fieldsConfig) {
        String fieldName = '';
        if (fieldConfig instanceof String) {
            fieldName = (String) fieldConfig;
        } else if (fieldConfig instanceof Map<String, Object>) {
            Map<String, Object> fieldMap2 = (Map<String, Object>) fieldConfig;
            fieldName = (String) fieldMap2.get('fieldName');
        }

        if (String.isNotBlank(fieldName)) {
            if (fieldName.contains('.')) {
                // Handle related fields (e.g., RecordType.Name or Owner.Name)
                if (fieldName.contains('Name') || fieldName.contains('DeveloperName')) {
                    searchableFields.add(fieldName);
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

                // Only include if filterable and not encrypted
                if (isTextType && describe.isFilterable() && !describe.isEncrypted()) {
                    searchableFields.add(fieldName);
                }
            }
        }
    }

    return searchableFields;
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