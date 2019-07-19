//===--- CIndexStoreDB.cpp ------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#include "CIndexStoreDB/CIndexStoreDB.h"
#include "IndexStoreDB/Index/IndexStoreLibraryProvider.h"
#include "IndexStoreDB/Index/IndexSystem.h"
#include "IndexStoreDB/Index/IndexSystemDelegate.h"
#include "IndexStoreDB/Core/Symbol.h"
#include "indexstore/IndexStoreCXX.h"
#include "llvm/ADT/IntrusiveRefCntPtr.h"
#include <Block.h>

using namespace IndexStoreDB;
using namespace index;

static indexstoredb_symbol_kind_t toCSymbolKind(SymbolKind K);

class IndexStoreDBObjectBase
    : public llvm::ThreadSafeRefCountedBase<IndexStoreDBObjectBase> {
public:
  virtual ~IndexStoreDBObjectBase() {}
};

template <typename T>
class IndexStoreDBObject: public IndexStoreDBObjectBase {
public:
  T value;

  IndexStoreDBObject(T value) : value(std::move(value)) {}
};

template <typename T>
static IndexStoreDBObject<T> *make_object(const T &value) {
  auto obj = new IndexStoreDBObject<T>(value);
  obj->Retain();
  return obj;
}

struct IndexStoreDBError {
  std::string message;
  IndexStoreDBError(StringRef message) : message(message.str()) {}
};

class BlockIndexStoreLibraryProvider : public IndexStoreLibraryProvider {
  indexstore_library_provider_t callback;

public:
  BlockIndexStoreLibraryProvider(indexstore_library_provider_t callback)
      : callback(Block_copy(callback)) {}
  ~BlockIndexStoreLibraryProvider() {
    Block_release(callback);
  }

  IndexStoreLibraryRef getLibraryForStorePath(StringRef storePath) override {
    indexstore_functions_t api;
    if (auto lib = callback(storePath.str().c_str())) {
      auto *obj = (IndexStoreDBObject<IndexStoreLibraryRef> *)lib;
      return obj->value;
    } else {
      return nullptr;
    }
  }
};

indexstoredb_index_t
indexstoredb_index_create(const char *storePath, const char *databasePath,
                          indexstore_library_provider_t libProvider,
                          bool readonly, bool listenToUnitEvents,
                          indexstoredb_error_t *error) {

  auto delegate = std::make_shared<IndexSystemDelegate>();
  auto libProviderObj = std::make_shared<BlockIndexStoreLibraryProvider>(libProvider);

  std::string errMsg;
  if (auto index =
          IndexSystem::create(storePath, databasePath, libProviderObj, delegate,
                              readonly, listenToUnitEvents, llvm::None, errMsg)) {

    return make_object(index);

  } else if (error) {
    *error = (indexstoredb_error_t)new IndexStoreDBError(errMsg);
  }
  return nullptr;
}

indexstoredb_indexstore_library_t
indexstoredb_load_indexstore_library(const char *dylibPath,
                                     indexstoredb_error_t *error) {
  std::string errMsg;
  if (auto lib = loadIndexStoreLibrary(dylibPath, errMsg)) {
    return make_object(lib);
  } else if (error) {
    *error = (indexstoredb_error_t)new IndexStoreDBError(errMsg);
  }
  return nullptr;
}

void indexstoredb_index_poll_for_unit_changes_and_wait(indexstoredb_index_t index) {
  auto obj = (IndexStoreDBObject<std::shared_ptr<IndexSystem>> *)index;
  obj->value->pollForUnitChangesAndWait();
}

bool
indexstoredb_index_symbol_occurrences_by_usr(
    indexstoredb_index_t index,
    const char *usr,
    uint64_t roles,
    indexstoredb_symbol_occurrence_receiver_t receiver)
{
  auto obj = (IndexStoreDBObject<std::shared_ptr<IndexSystem>> *)index;
  return obj->value->foreachSymbolOccurrenceByUSR(usr, (SymbolRoleSet)roles,
    [&](SymbolOccurrenceRef Occur) -> bool {
      return receiver(make_object(Occur));
    });
}

bool
indexstoredb_index_related_symbol_occurrences_by_usr(
    indexstoredb_index_t index,
    const char *usr,
    uint64_t roles,
    indexstoredb_symbol_occurrence_receiver_t receiver)
{
  auto obj = (IndexStoreDBObject<std::shared_ptr<IndexSystem>> *)index;
  return obj->value->foreachRelatedSymbolOccurrenceByUSR(usr, (SymbolRoleSet)roles,
    [&](SymbolOccurrenceRef Occur) -> bool {
      return receiver(make_object(Occur));
    });
}

bool
indexstoredb_index_symbol_occurrences_at_location(
    indexstoredb_index_t index,
    const char *path,
    int line,
    int utf8Column,
    uint64_t roles,
    indexstoredb_symbol_occurrence_receiver_t receiver)
{
  auto obj = (IndexStoreDBObject<std::shared_ptr<IndexSystem>> *)index;
  return obj->value->foreachSymbolOccurrenceAtLocation(StringRef(path), line, utf8Column, (SymbolRoleSet)roles, [&](SymbolOccurrenceRef occur) -> bool {
    return receiver(make_object(occur));
  });
}

const char *
indexstoredb_symbol_usr(indexstoredb_symbol_t symbol) {
  auto obj = (IndexStoreDBObject<std::shared_ptr<Symbol>> *)symbol;
  return obj->value->getUSR().c_str();
}

const char *
indexstoredb_symbol_name(indexstoredb_symbol_t symbol) {
  auto obj = (IndexStoreDBObject<std::shared_ptr<Symbol>> *)symbol;
  return obj->value->getName().c_str();
}

indexstoredb_symbol_kind_t
indexstoredb_symbol_kind(indexstoredb_symbol_t symbol) {
  auto symbolObj = (IndexStoreDBObject<std::shared_ptr<Symbol>> *)symbol;
  return toCSymbolKind(symbolObj->value->getSymbolKind());
}

bool
indexstoredb_index_symbol_names(indexstoredb_index_t index, indexstoredb_symbol_name_receiver receiver) {
  auto obj = (IndexStoreDBObject<std::shared_ptr<IndexSystem>> *)index;
  return obj->value->foreachSymbolName([&](StringRef ref) -> bool {
    return receiver(ref.str().c_str());
  });
}

bool
indexstoredb_index_canonical_symbol_occurences_by_name(
  indexstoredb_index_t index,
  const char *_Nonnull symbolName,
  indexstoredb_symbol_occurrence_receiver_t receiver)
{
  auto obj = (IndexStoreDBObject<std::shared_ptr<IndexSystem>> *)index;
  return obj->value->foreachCanonicalSymbolOccurrenceByName(symbolName, [&](SymbolOccurrenceRef occur) -> bool {
    return receiver(make_object(occur));
  });
}

bool
indexstoredb_index_canonical_symbol_occurences_containing_pattern(
  indexstoredb_index_t index,
  const char *_Nonnull pattern,
  bool anchorStart,
  bool anchorEnd,
  bool subsequence,
  bool ignoreCase,
  indexstoredb_symbol_occurrence_receiver_t receiver)
{
  auto obj = (IndexStoreDBObject<std::shared_ptr<IndexSystem>> *)index;
  return obj->value->foreachCanonicalSymbolOccurrenceContainingPattern(
    pattern,
    anchorStart,
    anchorEnd,
    subsequence,
    ignoreCase,
    [&](SymbolOccurrenceRef occur
  ) -> bool {
      return receiver(make_object(occur));
  });
}

indexstoredb_symbol_t
indexstoredb_symbol_occurrence_symbol(indexstoredb_symbol_occurrence_t occur) {
  auto obj = (IndexStoreDBObject<SymbolOccurrenceRef> *)occur;
  return make_object(obj->value->getSymbol());
}

uint64_t
indexstoredb_symbol_relation_get_roles(indexstoredb_symbol_relation_t relation) {
  auto relationObj = (IndexStoreDBObject<SymbolRelation> *)relation;
  return relationObj->value.getRoles().toRaw();
}

indexstoredb_symbol_t
indexstoredb_symbol_relation_get_symbol(indexstoredb_symbol_relation_t relation) {
  auto relationObj = (IndexStoreDBObject<SymbolRelation> *)relation;
  return make_object(relationObj->value.getSymbol());
}

bool
indexstoredb_symbol_occurrence_relations(indexstoredb_symbol_occurrence_t occurrence,
                                         bool(^applier)(indexstoredb_symbol_relation_t)) {
  auto occurrenceObj = (IndexStoreDBObject<SymbolOccurrenceRef> *)occurrence;
  ArrayRef<SymbolRelation> relations = occurrenceObj->value->getRelations();
  for (SymbolRelation rel : relations) {
    if(!applier(make_object(rel))) {
      return false;
    }
  }
  return true;
}

uint64_t
indexstoredb_symbol_occurrence_roles(indexstoredb_symbol_occurrence_t occur) {
  auto obj = (IndexStoreDBObject<SymbolOccurrenceRef> *)occur;
  return (uint64_t)obj->value->getRoles();
}

indexstoredb_symbol_location_t indexstoredb_symbol_occurrence_location(
    indexstoredb_symbol_occurrence_t occur) {
  auto obj = (IndexStoreDBObject<SymbolOccurrenceRef> *)occur;
  return (indexstoredb_symbol_location_t)&obj->value->getLocation();
}

const char *
indexstoredb_symbol_location_path(indexstoredb_symbol_location_t loc) {
  auto obj = (SymbolLocation *)loc;
  return obj->getPath().getPathString().c_str();
}

bool
indexstoredb_symbol_location_is_system(indexstoredb_symbol_location_t loc) {
  auto obj = (SymbolLocation *)loc;
  return obj->isSystem();
}

int
indexstoredb_symbol_location_line(indexstoredb_symbol_location_t loc) {
  auto obj = (SymbolLocation *)loc;
  return obj->getLine();
}

int
indexstoredb_symbol_location_column_utf8(indexstoredb_symbol_location_t loc) {
  auto obj = (SymbolLocation *)loc;
  return obj->getColumn();
}

indexstoredb_object_t indexstoredb_retain(indexstoredb_object_t obj) {
  if (obj)
    ((IndexStoreDBObjectBase *)obj)->Retain();
  return obj;
}

void
indexstoredb_release(indexstoredb_object_t obj) {
  if (obj)
    ((IndexStoreDBObjectBase *)obj)->Release();
}

const char *
indexstoredb_error_get_description(indexstoredb_error_t error) {
  return ((IndexStoreDBError *)error)->message.c_str();
}

void
indexstoredb_error_dispose(indexstoredb_error_t error) {
  if (error)
   delete (IndexStoreDBError *)error;
}

static indexstoredb_symbol_kind_t toCSymbolKind(SymbolKind K) {
  switch (K) {
  case SymbolKind::Unknown:
    return INDEXSTOREDB_SYMBOL_KIND_UNKNOWN;
  case SymbolKind::Module:
    return INDEXSTOREDB_SYMBOL_KIND_MODULE;
  case SymbolKind::Namespace:
    return INDEXSTOREDB_SYMBOL_KIND_NAMESPACE;
  case SymbolKind::NamespaceAlias:
    return INDEXSTOREDB_SYMBOL_KIND_NAMESPACEALIAS;
  case SymbolKind::Macro:
    return INDEXSTOREDB_SYMBOL_KIND_MACRO;
  case SymbolKind::Enum:
    return INDEXSTOREDB_SYMBOL_KIND_ENUM;
  case SymbolKind::Struct:
    return INDEXSTOREDB_SYMBOL_KIND_STRUCT;
  case SymbolKind::Class:
    return INDEXSTOREDB_SYMBOL_KIND_CLASS;
  case SymbolKind::Protocol:
    return INDEXSTOREDB_SYMBOL_KIND_PROTOCOL;
  case SymbolKind::Extension:
    return INDEXSTOREDB_SYMBOL_KIND_EXTENSION;
  case SymbolKind::Union:
    return INDEXSTOREDB_SYMBOL_KIND_UNION;
  case SymbolKind::TypeAlias:
    return INDEXSTOREDB_SYMBOL_KIND_TYPEALIAS;
  case SymbolKind::Function:
    return INDEXSTOREDB_SYMBOL_KIND_FUNCTION;
  case SymbolKind::Variable:
    return INDEXSTOREDB_SYMBOL_KIND_VARIABLE;
  case SymbolKind::Parameter:
    return INDEXSTOREDB_SYMBOL_KIND_PARAMETER;
  case SymbolKind::Field:
    return INDEXSTOREDB_SYMBOL_KIND_FIELD;
  case SymbolKind::EnumConstant:
    return INDEXSTOREDB_SYMBOL_KIND_ENUMCONSTANT;
  case SymbolKind::InstanceMethod:
    return INDEXSTOREDB_SYMBOL_KIND_INSTANCEMETHOD;
  case SymbolKind::ClassMethod:
    return INDEXSTOREDB_SYMBOL_KIND_CLASSMETHOD;
  case SymbolKind::StaticMethod:
    return INDEXSTOREDB_SYMBOL_KIND_STATICMETHOD;
  case SymbolKind::InstanceProperty:
    return INDEXSTOREDB_SYMBOL_KIND_INSTANCEPROPERTY;
  case SymbolKind::ClassProperty:
    return INDEXSTOREDB_SYMBOL_KIND_CLASSPROPERTY;
  case SymbolKind::StaticProperty:
    return INDEXSTOREDB_SYMBOL_KIND_STATICPROPERTY;
  case SymbolKind::Constructor:
    return INDEXSTOREDB_SYMBOL_KIND_CONSTRUCTOR;
  case SymbolKind::Destructor:
    return INDEXSTOREDB_SYMBOL_KIND_DESTRUCTOR;
  case SymbolKind::ConversionFunction:
    return INDEXSTOREDB_SYMBOL_KIND_CONVERSIONFUNCTION;
  case SymbolKind::CommentTag:
    return INDEXSTOREDB_SYMBOL_KIND_COMMENTTAG;
  default:
    return INDEXSTOREDB_SYMBOL_KIND_UNKNOWN;
  }
}
