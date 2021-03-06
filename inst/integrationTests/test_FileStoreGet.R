#
# Integration tests for synGet, synStore and related functions
#

.setUp <- function() {
  ## create a project to fill with entities
  project <- createEntity(Project())
  synapseClient:::.setCache("testProject", project)
  # initialize this list
  synapseClient:::.setCache("foldersToDelete", list())
}

.tearDown <- function() {
  ## delete the test project
  deleteEntity(synapseClient:::.getCache("testProject"))
  
  foldersToDelete<-synapseClient:::.getCache("foldersToDelete")
  for (folder in foldersToDelete) {
    if (file.exists(folder)) {
      unlink(folder, recursive=TRUE)
    }
  }
  synapseClient:::.setCache("foldersToDelete", list())
  
  ## in the case that we have 'mocked' hasUnfulfilledAccessRequirements, this restores the original function
  if (!is.null(synapseClient:::.getCache("hasUnfulfilledAccessRequirementsIsOverRidden"))) {
    assignInNamespace("hasUnfulfilledAccessRequirements", attr(synapseClient:::hasUnfulfilledAccessRequirements, "origDef"), "synapseClient")
    synapseClient:::.setCache("hasUnfulfilledAccessRequirementsIsOverRidden", NULL)
  }
  
}

createFile<-function() {
  filePath<- tempfile()
  connection<-file(filePath)
  writeChar("this is a test", connection, eos=NULL)
  close(connection)  
  filePath
}

integrationTestCacheMapRoundTrip <- function() {
  fileHandleId<-"TEST_FHID"
  filePath<- createFile()
  filePath2<- createFile()
  
 
  synapseClient:::addToCacheMap(fileHandleId, filePath)
  synapseClient:::addToCacheMap(fileHandleId, filePath2)
  content<-synapseClient:::getCacheMapFileContent(fileHandleId)
  checkEquals(2, length(content))
  checkTrue(any(normalizePath(filePath, winslash="/")==names(content)))
  checkTrue(any(normalizePath(filePath2, winslash="/")==names(content)))
  checkEquals(synapseClient:::.formatAsISO8601(file.info(filePath)$mtime), synapseClient:::getFromCacheMap(fileHandleId, filePath))
  checkEquals(synapseClient:::.formatAsISO8601(file.info(filePath2)$mtime), synapseClient:::getFromCacheMap(fileHandleId, filePath2))
  checkTrue(synapseClient:::localFileUnchanged(fileHandleId, filePath))
  checkTrue(synapseClient:::localFileUnchanged(fileHandleId, filePath2))
  
  # now clean up
  scheduleCacheFolderForDeletion(fileHandleId)
}

scheduleFolderForDeletion<-function(folder) {
  folderList<-synapseClient:::.getCache("foldersToDelete")
  folderList[[length(folderList)+1]]<-folder
  synapseClient:::.setCache("foldersToDelete", folderList)
}

scheduleCacheFolderForDeletion<-function(fileHandleId) {
  if (is.null(fileHandleId)) stop("In scheduleCacheFolderForDeletion fileHandleId must not be null")
  scheduleFolderForDeletion(synapseClient:::defaultDownloadLocation(fileHandleId))
}

integrationTestMetadataRoundTrip <- function() {
  # create a Project
  project <- synapseClient:::.getCache("testProject")
  checkTrue(!is.null(project))
  
  # create a file to be uploaded
  filePath<- createFile()
  synapseStore<-TRUE
  file<-File(filePath, synapseStore, parentId=propertyValue(project, "id"))
  checkTrue(!is.null(propertyValue(file, "name")))
  checkEquals(propertyValue(project, "id"), propertyValue(file, "parentId"))
  
  # now store it
  storedFile<-synStore(file)
  scheduleCacheFolderForDeletion(storedFile@fileHandle$id)
  
  metadataOnly<-synGet(propertyValue(storedFile, "id"),downloadFile=F)
  metadataOnly<-synapseClient:::synAnnotSetMethod(metadataOnly, "annot", "value")
  storedMetadata<-synStore(metadataOnly, forceVersion=F)
  
  checkEquals("value", synapseClient:::synAnnotGetMethod(storedMetadata, "annot"))
  
  checkEquals(1, propertyValue(metadataOnly, "versionNumber"))
  
  # now store again, but force a version update
  storedMetadata<-synStore(storedMetadata) # default is forceVersion=T
  
  retrievedMetadata<-synGet(propertyValue(storedFile, "id"),downloadFile=F)
  checkEquals(2, propertyValue(retrievedMetadata, "versionNumber"))
  # no file location since we haven't downloaded anything
  checkEquals(character(0), getFileLocation(retrievedMetadata))
  
  # of course we should still be able to get the original version
  originalVersion<-synGet(propertyValue(storedFile, "id"), version=1, downloadFile=F)
  checkEquals(1, propertyValue(originalVersion, "versionNumber"))
  # ...whether or not we download the file
  originalVersion<-synGet(propertyValue(storedFile, "id"), version=1, downloadFile=T)
  checkEquals(1, propertyValue(originalVersion, "versionNumber"))
  # file location is NOT missing
  checkTrue(length(getFileLocation(originalVersion))>0)
}

integrationTestGovernanceRestriction <- function() {
  project <- synapseClient:::.getCache("testProject")
  checkTrue(!is.null(project))
  
  # create a File
  filePath<- createFile()
  synapseStore<-TRUE
  file<-File(filePath, synapseStore, parentId=propertyValue(project, "id"))
  storedFile<-synStore(file)
  id<-propertyValue(storedFile, "id")
  scheduleCacheFolderForDeletion(storedFile@fileHandle$id)
  
  # mock Governance restriction
  myHasUnfulfilledAccessRequirements<-function(id) {TRUE} # return TRUE, i.e. yes, there are unfulfilled access requiremens
  attr(myHasUnfulfilledAccessRequirements, "origDef") <- synapseClient:::hasUnfulfilledAccessRequirements
  assignInNamespace("hasUnfulfilledAccessRequirements", myHasUnfulfilledAccessRequirements, "synapseClient")
  synapseClient:::.setCache("hasUnfulfilledAccessRequirementsIsOverRidden", TRUE)
  
  # try synGet with downloadFile=F, load=F, should be OK
  synGet(id, downloadFile=F, load=F)
  
  # try synGet with downloadFile=T, should NOT be OK
  result<-try(synGet(id, downloadFile=T, load=F), silent=TRUE)
  checkEquals("try-error", class(result))
  
  # try synGet with load=T, should NOT be OK
  result<-try(synGet(id, downloadFile=F, load=T), silent=TRUE)
  checkEquals("try-error", class(result))

}

# utility to change the timestamp on a file
touchFile<-function(location) {
  orginalTimestamp<-synapseClient:::lastModifiedTimestamp(location)
  Sys.sleep(1.0) # make sure new timestamp will be different from original
  connection<-file(location)
  # result<-paste(readLines(connection), collapse="\n")
  originalSize<-file.info(location)$size
  originalMD5<-tools::md5sum(location)
  result<-readChar(connection, originalSize)
  close(connection)
  connection<-file(location)
  # writeLines(result, connection)
  writeChar(result, connection, eos=NULL)
  close(connection)  
  # check that we indeed modified the time stamp on the file
  newTimestamp<-synapseClient:::lastModifiedTimestamp(location)
  checkTrue(newTimestamp!=orginalTimestamp)
  # check that the file has not been changed
  checkEquals(originalMD5, tools::md5sum(location))
}

checkFilesEqual<-function(file1, file2) {
  checkEquals(normalizePath(file1, winslash="/"), normalizePath(file2, winslash="/"))
}

integrationTestCreateOrUpdate<-function() {
  # create a Project
  project <- synapseClient:::.getCache("testProject")
  checkTrue(!is.null(project))
  createOrUpdateIntern(project)
  
}

createOrUpdateIntern<-function(project) {
  filePath<- createFile()
  name<-"createOrUpdateTest"
  pid<-propertyValue(project, "id")
  file<-File(filePath, name=name, parentId=pid)
  file<-synStore(file)
  
  filePath2<- createFile()
  file2<-File(filePath2, name=name, parentId=pid)
  # since createOrUpdate=T is the default, this should update 'file' rather than create a new one
  file2<-synStore(file2)
  checkEquals(propertyValue(file, "id"), propertyValue(file2, "id"))
  
  filePath3 <- createFile()
  file3<-File(filePath3, name=name, parentId=pid)
  result<-try(synStore(file3, createOrUpdate=F), silent=T)
  checkEquals("try-error", class(result))
  
  # check an entity with no parent
  project2<-Project(name=propertyValue(project, "name"))
  project2<-synStore(project2)
  checkEquals(propertyValue(project2, "id"), pid)
  
  project3<-Project(name=propertyValue(project, "name"))
  result<-try(synStore(project3, createOrUpdate=F), silent=T)
  checkEquals("try-error", class(result))
}

#
# This code exercises the file services underlying upload/download to/from an entity
#
integrationTestRoundtrip <- function()
{
  # create a Project
  project <- synapseClient:::.getCache("testProject")
  checkTrue(!is.null(project))
  roundTripIntern(project)
}

roundTripIntern<-function(project) {  
  # create a file to be uploaded
  filePath<- createFile()
  synapseStore<-TRUE
  file<-File(filePath, synapseStore, parentId=propertyValue(project, "id"))
  checkTrue(!is.null(propertyValue(file, "name")))
  checkEquals(propertyValue(project, "id"), propertyValue(file, "parentId"))
  
  # now store it
  storedFile<-synStore(file)
  scheduleCacheFolderForDeletion(storedFile@fileHandle$id)
  
  # check that it worked
  checkTrue(!is.null(storedFile))
  id<-propertyValue(storedFile, "id")
  checkTrue(!is.null(id))
  checkEquals(propertyValue(project, "id"), propertyValue(storedFile, "parentId"))
  checkEquals(propertyValue(file, "name"), propertyValue(storedFile, "name"))
  checkEquals(filePath, getFileLocation(storedFile))
  checkEquals(synapseStore, storedFile@synapseStore)
  
  # check that cachemap entry exists
  fileHandleId<-storedFile@fileHandle$id
  cachePath<-sprintf("%s/.cacheMap", synapseClient:::defaultDownloadLocation(fileHandleId))
  checkTrue(file.exists(cachePath))
  modifiedTimeStamp<-synapseClient:::getFromCacheMap(fileHandleId, filePath)
  checkTrue(!is.null(modifiedTimeStamp))
  
  # now download it.  This will pull a new copy into the cache
  downloadedFile<-synGet(id)
  downloadedFilePathInCache<-getFileLocation(downloadedFile)
  checkEquals(id, propertyValue(downloadedFile, "id"))
  checkEquals(propertyValue(project, "id"), propertyValue(downloadedFile, "parentId"))
  checkEquals(synapseStore, downloadedFile@synapseStore)
  checkTrue(length(getFileLocation(downloadedFile))>0)
  
  # compare MD-5 checksum of filePath and downloadedFile@filePath
  origChecksum<- as.character(tools::md5sum(filePath))
  downloadedChecksum <- as.character(tools::md5sum(getFileLocation(downloadedFile)))
  checkEquals(origChecksum, downloadedChecksum)
  
  checkEquals(storedFile@fileHandle, downloadedFile@fileHandle)
  
  # test synStore of retrieved entity, no change to file
  modifiedTimeStamp<-synapseClient:::getFromCacheMap(fileHandleId, downloadedFilePathInCache)
  checkTrue(!is.null(modifiedTimeStamp))
  Sys.sleep(1.0)
  updatedFile <-synStore(downloadedFile, forceVersion=F)
  # the file handle should be the same
  checkEquals(fileHandleId, propertyValue(updatedFile, "dataFileHandleId"))
  # there should be no change in the time stamp.
  checkEquals(modifiedTimeStamp, synapseClient:::getFromCacheMap(fileHandleId, downloadedFilePathInCache))
  # we are still on version 1
  checkEquals(1, propertyValue(updatedFile, "versionNumber"))

  #  test synStore of retrieved entity, after changing file
  # modify the file
  touchFile(downloadedFilePathInCache)
  
  updatedFile2 <-synStore(updatedFile, forceVersion=F)
  scheduleCacheFolderForDeletion(updatedFile2@fileHandle$id)
  # fileHandleId is changed
  checkTrue(fileHandleId!=propertyValue(updatedFile2, "dataFileHandleId"))
  # we are now on version 2
  checkEquals(2, propertyValue(updatedFile2, "versionNumber"))
  
  # of course we should still be able to get the original version
  originalVersion<-synGet(propertyValue(storedFile, "id"), version=1, downloadFile=F)
  checkEquals(1, propertyValue(originalVersion, "versionNumber"))
  # ...whether or not we download the file
  originalVersion<-synGet(propertyValue(storedFile, "id"), version=1, downloadFile=T)
  checkEquals(1, propertyValue(originalVersion, "versionNumber"))
  
  # get the current version of the file, but download it to a specified location
  # (make the location unique)
  specifiedLocation<-file.path(tempdir(), "subdir")
  checkTrue(dir.create(specifiedLocation))
  scheduleFolderForDeletion(specifiedLocation)
  downloadedToSpecified<-synGet(id, downloadLocation=specifiedLocation)
  checkFilesEqual(specifiedLocation, dirname(getFileLocation(downloadedToSpecified)))
  fp<-getFileLocation(downloadedToSpecified)
  checkEquals(fp, file.path(specifiedLocation, basename(filePath)))
  checkTrue(file.exists(fp))
  touchFile(fp)

  timestamp<-synapseClient:::lastModifiedTimestamp(fp)
  
  # download again with the 'keep.local' choice
  downloadedToSpecified<-synGet(id, downloadLocation=specifiedLocation, ifcollision="keep.local")
  # file path is the same, timestamp should not change
  Sys.sleep(1.0)
  checkEquals(getFileLocation(downloadedToSpecified), fp)
  checkEquals(timestamp, synapseClient:::lastModifiedTimestamp(fp))
  
  # download again with the 'overwrite' choice
  downloadedToSpecified<-synGet(id, downloadLocation=specifiedLocation, ifcollision="overwrite.local")
  checkEquals(getFileLocation(downloadedToSpecified), fp)
  # timestamp SHOULD change
  checkTrue(timestamp!=synapseClient:::lastModifiedTimestamp(fp)) 

  touchFile(fp)
  Sys.sleep(1.0)
  # download with the 'keep both' choice (the default)
  downloadedToSpecified<-synGet(id, downloadLocation=specifiedLocation)
  # there should be a second file
  checkTrue(getFileLocation(downloadedToSpecified)!=fp)
  # it IS in the specified directory
  checkFilesEqual(specifiedLocation, dirname(getFileLocation(downloadedToSpecified)))
  
  # delete the cached file
  deleteEntity(downloadedFile)
  # clean up downloaded file
  handleUri<-sprintf("/fileHandle/%s", storedFile@fileHandle$id)
  synapseClient:::synapseDelete(handleUri, service="FILE")
  handleUri<-sprintf("/fileHandle/%s", updatedFile2@fileHandle$id)
  synapseClient:::synapseDelete(handleUri, service="FILE")
}


# test that legacy *Entity based methods work on File objects
integrationTestAddToNewFILEEntity <-
  function()
{
  project <- synapseClient:::.getCache("testProject")
  filePath<- createFile()
  file<-FileListConstructor(list(parentId=propertyValue(project, "id")))
  file<-addFile(file, filePath)
  storedFile<-storeEntity(file)
  scheduleCacheFolderForDeletion(storedFile@fileHandle$id)
  
  checkTrue(!is.null(storedFile))
  id<-propertyValue(storedFile, "id")
  checkTrue(!is.null(id))
  checkEquals(propertyValue(project, "id"), propertyValue(storedFile, "parentId"))
  checkEquals(propertyValue(file, "name"), propertyValue(storedFile, "name"))
  checkEquals(filePath, getFileLocation(storedFile))
  checkEquals(TRUE, storedFile@synapseStore) # this is the default
  checkTrue(!is.null(propertyValue(storedFile, "dataFileHandleId")))
  
  gotEntity<-getEntity(storedFile) # get metadata, don't download file
  
  checkTrue(!is.null(gotEntity))
  id<-propertyValue(gotEntity, "id")
  checkTrue(!is.null(id))
  checkEquals(propertyValue(project, "id"), propertyValue(gotEntity, "parentId"))
  checkEquals(propertyValue(file, "name"), propertyValue(gotEntity, "name"))
  checkTrue(!is.null(propertyValue(gotEntity, "dataFileHandleId")))
  checkTrue(length(getFileLocation(gotEntity))==0) # empty since it hasn't been downloaded
  
  # test update of metadata
  annotValue(gotEntity, "foo")<-"bar"
  updatedEntity<-updateEntity(gotEntity)
  gotEntity<-getEntity(updatedEntity)
  checkEquals("bar", annotValue(gotEntity, "foo"))
  
  downloadedFile<-downloadEntity(id)
  checkEquals(id, propertyValue(downloadedFile, "id"))
  checkEquals(propertyValue(project, "id"), propertyValue(downloadedFile, "parentId"))
  checkEquals(TRUE, downloadedFile@synapseStore) # this is the default
  checkTrue(!is.null(getFileLocation(downloadedFile)))
  
  # compare MD-5 checksum of filePath and downloadedFile@filePath
  origChecksum<- as.character(tools::md5sum(filePath))
  downloadedChecksum <- as.character(tools::md5sum(getFileLocation(downloadedFile)))
  checkEquals(origChecksum, downloadedChecksum)
  
  checkEquals(storedFile@fileHandle, downloadedFile@fileHandle)
  
  # check that downloading a second time doesn't retrieve again
  timeStamp<-synapseClient:::lastModifiedTimestamp(getFileLocation(downloadedFile))
  Sys.sleep(1.0)
  downloadedFile<-downloadEntity(id)
  checkEquals(timeStamp, synapseClient:::lastModifiedTimestamp(getFileLocation(downloadedFile)))
 
  # delete the file
  deleteEntity(downloadedFile)
  # clean up downloaded file
  handleUri<-sprintf("/fileHandle/%s", storedFile@fileHandle$id)
  synapseClient:::synapseDelete(handleUri, service="FILE")
}

# test that legacy *Entity based methods work on File objects, cont.
integrationTestReplaceFile<-function() {
    project <- synapseClient:::.getCache("testProject")
    filePath<- createFile()
    file<-FileListConstructor(list(parentId=propertyValue(project, "id")))
    file<-addFile(file, filePath)
    # replace storeEntity with createEntity
    storedFile<-createEntity(file)
    scheduleCacheFolderForDeletion(storedFile@fileHandle$id)
    
    # now getEntity, add a different file, store, retrieve
    gotEntity<-getEntity(storedFile) # get metadata, don't download file
    newFile<-system.file("DESCRIPTION", package = "synapseClient")
    gotEntity<-addFile(gotEntity, newFile)
    newStoredFile<-storeEntity(gotEntity)
    scheduleCacheFolderForDeletion(newStoredFile@fileHandle$id)
    
    downloadedFile<-downloadEntity(newStoredFile)
 
    # compare MD-5 checksum of filePath and downloadedFile@filePath
    origChecksum<- as.character(tools::md5sum(newFile))
    downloadedChecksum <- as.character(tools::md5sum(getFileLocation(downloadedFile)))
    checkEquals(origChecksum, downloadedChecksum)
    
    checkEquals(newStoredFile@fileHandle, downloadedFile@fileHandle)
    
    # delete the file
    deleteEntity(downloadedFile)
    # clean up downloaded file
    handleUri<-sprintf("/fileHandle/%s", newStoredFile@fileHandle$id)
    synapseClient:::synapseDelete(handleUri, service="FILE")
  }



integrationTestLoadEntity<-function() {
  project <- synapseClient:::.getCache("testProject")
  filePath<- createFile()
  file<-FileListConstructor(list(parentId=propertyValue(project, "id")))
  dataObject<-list(a="A", b="B", c="C")
  file<-addObject(file, dataObject, "dataObjectName")
  storedFile<-createEntity(file)
  scheduleCacheFolderForDeletion(storedFile@fileHandle$id)
  
  loadedEntity<-loadEntity(propertyValue(storedFile, "id"))
  
  checkEquals(dataObject, getObject(loadedEntity, "dataObjectName"))
  
  # can load from an entity as well as from an ID
  loadedEntity2<-loadEntity(storedFile)
  checkEquals(dataObject, getObject(loadedEntity2, "dataObjectName"))
  
  # delete the file
  deleteEntity(loadedEntity)
  # clean up downloaded file
  handleUri<-sprintf("/fileHandle/%s", loadedEntity2@fileHandle$id)
  synapseClient:::synapseDelete(handleUri, service="FILE")
}

integrationTestSerialization<-function() {
  project <- synapseClient:::.getCache("testProject")
  myData<-list(foo="bar", foo2="bas")
  file<-File(myData)
  # note, it does NOT currently work to call file<-File(data, parentId=<pid>)
  propertyValue(file, "parentId")<-propertyValue(project, "id")
  storedFile<-synStore(file)
  scheduleCacheFolderForDeletion(storedFile@fileHandle$id)
  checkTrue(!is.null(getFileLocation(storedFile)))
  id<-propertyValue(storedFile, "id")
  checkTrue(!is.null(id))
  retrievedFile<-synGet(id, load=T)
  checkTrue(synapseClient:::hasObjects(retrievedFile))
  retrievedObject<-getObject(retrievedFile, "myData")
  checkEquals(myData, retrievedObject)
}

integrationTestNonFile<-function() {
  project <- synapseClient:::.getCache("testProject")
  folder<-Folder(name="test folder", parentId=propertyValue(project, "id"))
  folder<-synapseClient:::synAnnotSetMethod(folder, "annot", "value")
  storedFolder<-synStore(folder)
  id<-propertyValue(storedFolder, "id")
  checkTrue(!is.null(id))
  
  retrievedFolder<-synGet(id)
  checkEquals(propertyValue(project, "id"), propertyValue(retrievedFolder, "parentId"))
  checkEquals("value", synapseClient:::synAnnotGetMethod(retrievedFolder, "annot"))
  
  # TODO test createORUpdate
}

# this tests synStore in which the activity name, description, used, and executed param's are passed in
integrationTestProvenance<-function() {
  project <- synapseClient:::.getCache("testProject")
  pid<-propertyValue(project, "id")
  executed<-Folder(name="executed", parentId=pid)
  executed<-synStore(executed)
  
  folder<-Folder(name="test folder", parentId=pid)
  # this tests (1) linking a URL, (2) passing a list, (3) passing a single entity, (4) passing an entity ID
  storedFolder<-synStore(folder, used=list("http://foo.bar.com", project), executed=propertyValue(executed, "id"), 
    activityName="activity name", activityDescription="activity description")
  id<-propertyValue(storedFolder, "id")
  checkTrue(!is.null(id))
  
  retrievedFolder<-synGet(id)
  checkEquals(propertyValue(project, "id"), propertyValue(retrievedFolder, "parentId"))
  activity<-generatedBy(retrievedFolder)
  checkEquals("activity name", propertyValue(activity, "name"))
  checkEquals("activity description", propertyValue(activity, "description"))
  
  # now check the 'used' list
  used<-propertyValue(activity, "used")
  checkEquals(3, length(used))
  foundURL<-F
  foundProject<-F
  foundExecuted<-F
  for (u in used) {
    if (u$concreteType=="org.sagebionetworks.repo.model.provenance.UsedURL") {
      checkEquals(FALSE, u$wasExecuted)
      checkEquals("http://foo.bar.com", u$url)
      foundURL<-T
    } else {
      checkEquals(u$concreteType, "org.sagebionetworks.repo.model.provenance.UsedEntity")
      if (u$wasExecuted) {
        checkEquals(u$reference$targetId, propertyValue(executed, "id"))
        checkEquals(u$reference$targetVersionNumber, 1)
        foundExecuted<- T
      } else {
        checkEquals(u$reference$targetId, propertyValue(project, "id"))
        checkEquals(u$reference$targetVersionNumber, 1)
        foundProject<- T
      }
    }
  }
  checkTrue(foundURL)
  checkTrue(foundProject)
  checkTrue(foundExecuted)
}

# this tests synStore where an Activity is constructed separately, then passed in
integrationTestProvenance2<-function() {
  project <- synapseClient:::.getCache("testProject")
  pid<-propertyValue(project, "id")
  executed<-Folder(name="executed", parentId=pid)
  executed<-synStore(executed)
  
  folder<-Folder(name="test folder", parentId=pid)
  # this tests (1) linking a URL, (2) passing a list, (3) passing a single entity, (4) passing an entity ID
  activity<-Activity(
    list(name="activity name", description="activity description",
            used=list(
              list(url="http://foo.bar.com", wasExecuted=F),
              list(entity=pid, wasExecuted=F),
              list(entity=propertyValue(executed, "id"), wasExecuted=T)
          )
      )
  )
  activity<-storeEntity(activity)
  
  storedFolder<-synStore(folder, activity=activity)
  id<-propertyValue(storedFolder, "id")
  checkTrue(!is.null(id))
  
  # make sure that using an Activity elsewhere doesn't cause a problem
  anotherFolder<-Folder(name="another folder", parentId=pid)
  anotherFolder<-synStore(anotherFolder, activity=activity)
  
  checkEquals(propertyValue(generatedBy(storedFolder), "id"), propertyValue(generatedBy(anotherFolder), "id"))
  
  # now retrieve the first folder and check the provenance
  retrievedFolder<-synGet(id)
  checkEquals(propertyValue(project, "id"), propertyValue(retrievedFolder, "parentId"))
  activity<-generatedBy(retrievedFolder)
  checkEquals("activity name", propertyValue(activity, "name"))
  checkEquals("activity description", propertyValue(activity, "description"))
  
  # now check the 'used' list
  used<-propertyValue(activity, "used")
  checkEquals(3, length(used))
  foundURL<-F
  foundProject<-F
  foundExecuted<-F
  for (u in used) {
    if (u$concreteType=="org.sagebionetworks.repo.model.provenance.UsedURL") {
      checkEquals(FALSE, u$wasExecuted)
      checkEquals("http://foo.bar.com", u$url)
      foundURL<-T
    } else {
      checkEquals(u$concreteType, "org.sagebionetworks.repo.model.provenance.UsedEntity")
      if (u$wasExecuted) {
        checkEquals(u$reference$targetId, propertyValue(executed, "id"))
        checkEquals(u$reference$targetVersionNumber, 1)
        foundExecuted<- T
      } else {
        checkEquals(u$reference$targetId, propertyValue(project, "id"))
        checkEquals(u$reference$targetVersionNumber, 1)
        foundProject<- T
      }
    }
  }
  checkTrue(foundURL)
  checkTrue(foundProject)
  checkTrue(foundExecuted)
}

integrationTestExternalLink<-function() {
  project <- synapseClient:::.getCache("testProject")
  pid<-propertyValue(project, "id")
  
  # create a file to be uploaded
  synapseStore<-FALSE
  filePath<-"http://dilbert.com/index.html"
  file<-File(filePath, synapseStore, parentId=propertyValue(project, "id"))
  
  # now store it
  storedFile<-synStore(file)
  
  # check that it worked
  checkTrue(!is.null(storedFile))
  id<-propertyValue(storedFile, "id")
  checkTrue(!is.null(id))
  checkEquals(propertyValue(project, "id"), propertyValue(storedFile, "parentId"))
  checkEquals(filePath, getFileLocation(storedFile))
  checkEquals(synapseStore, storedFile@synapseStore)
  
  # check that cachemap entry does NOT exist
  fileHandleId<-storedFile@fileHandle$id
  cachePath<-sprintf("%s/.cacheMap", synapseClient:::defaultDownloadLocation(fileHandleId))
  checkTrue(!file.exists(cachePath))
  
  # retrieve the metadata (no download)
  metadataOnly<-synGet(id, downloadFile=FALSE)
  # no file path when retrieving only metadata
  checkEquals(character(0), getFileLocation(metadataOnly))
  
  # now download it.  This will pull a copy into the cache
  downloadedFile<-synGet(id)
  scheduleCacheFolderForDeletion(downloadedFile@fileHandle$id)
  
  checkEquals(id, propertyValue(downloadedFile, "id"))
  checkEquals(propertyValue(project, "id"), propertyValue(downloadedFile, "parentId"))
  checkEquals(synapseStore, downloadedFile@synapseStore)
  # no file path when retrieving only metadata
  checkEquals(character(0), getFileLocation(metadataOnly))
  checkEquals(filePath, downloadedFile@fileHandle$externalURL)
}

