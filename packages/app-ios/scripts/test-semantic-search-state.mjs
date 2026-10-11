// SPDX-License-Identifier: GPL-3.0-or-later
import {execFileSync} from 'node:child_process';
import {mkdtempSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const app=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const temp=mkdtempSync(join(tmpdir(),'readany-semantic-search-'));
try {
 const src=readFileSync(join(app,'Shudeng/Features/Library/LibraryStore.swift'),'utf8');
 const start=src.indexOf('    func searchSemantics(');
 const end=src.indexOf('\n    static func embeddingInfo',start);
 const method=src.slice(start,end);
 const typeStart=src.indexOf('    struct SemanticHit:');
 const typeEnd=src.indexOf('    /// 已经建过语义索引的书。',typeStart);
 writeFileSync(join(temp,'Test.swift'),`import Foundation
 @MainActor final class RuntimeHost {
  enum State { case ready, unavailable }
  var state=State.ready
  var pending:[(String)->Void]=[]
  func callAsync(_ expression:String,timeout:TimeInterval,onResult:@escaping(String)->Void) { pending.append(onResult) }
 }
 @MainActor final class LibraryStore {
  ${src.slice(typeStart,typeEnd)}
  var searchGeneration=0, indexedBooks=[1], isSearchingSemantics=false
  var semanticHits:[SemanticHit]=[], semanticFailures:[SemanticFailure]=[], semanticError:String?
  static func payload(_ input:[String:Any])->String { "{}" }
  ${method}
 }
 @main struct Tests {
  @MainActor static func main() async {
   var checks=0
   func expect(_ value:Bool,_ name:String) { checks += 1; if !value { print("FAIL: " + name); exit(1) } }
   func pending(_ host:RuntimeHost,_ count:Int) async { while host.pending.count<count { await Task.yield() } }
   let store=LibraryStore(), host=RuntimeHost()
   let task=Task { await store.searchSemantics(query:"database",using:host) }
   await pending(host,1)
   expect(store.isSearchingSemantics,"loading shown while pending")
   host.pending[0](#"{"error":"no such table: vector_index_provenance"}"#)
   await task.value
   expect(store.semanticError != nil && !store.isSearchingSemantics,"runtime failure must not masquerade as no matches")
   let retry=Task { await store.searchSemantics(query:"database",using:host) }
   await pending(host,2)
   expect(store.semanticError == nil && store.isSearchingSemantics,"retry clears error and starts loading")
   host.pending[1](#"{"results":[{"bookId":"b","bookTitle":"sample","chapterIndex":1,"chapterTitle":"chapter","content":"SQLite database","score":0.9}],"errors":[]}"#)
   await retry.value
   expect(store.semanticError == nil && store.semanticHits.count==1 && !store.isSearchingSemantics,"successful retry recovers exact hit")
   let malformed=Task { await store.searchSemantics(query:"database",using:host) }
   await pending(host,3);host.pending[2]("{}");await malformed.value
   expect(store.semanticError != nil,"malformed response is an error")
   let zero=Task { await store.searchSemantics(query:"absent",using:host) }
   await pending(host,4);host.pending[3](#"{"results":[],"errors":[]}"#);await zero.value
   expect(store.semanticError == nil && store.semanticHits.isEmpty,"valid zero remains empty without error")
   let partial=Task { await store.searchSemantics(query:"known",using:host) }
   await pending(host,5);host.pending[4](#"{"results":[],"errors":[{"bookId":"b","message":"incompatible"}]}"#);await partial.value
   expect(store.semanticError == nil && store.semanticFailures.count==1,"book-specific failures retained")
   let stale=Task { await store.searchSemantics(query:"old",using:host) }
   await pending(host,6)
   let fresh=Task { await store.searchSemantics(query:"new",using:host) }
   await pending(host,7);host.pending[6](#"{"results":[],"errors":[]}"#);await fresh.value
   host.pending[5](#"{"error":"late old failure"}"#);await stale.value
   expect(store.semanticError == nil && !store.isSearchingSemantics,"stale failure cannot overwrite newer search")
   let clear=Task { await store.searchSemantics(query:"pending",using:host) }
   await pending(host,8);await store.searchSemantics(query:"",using:host)
   host.pending[7](#"{"error":"after clear"}"#);await clear.value
   expect(store.semanticError == nil && store.semanticHits.isEmpty && store.semanticFailures.isEmpty && !store.isSearchingSemantics,"clear cancels old error")
   print("Semantic search regression passed (\\(checks) checks)")
  }
 }
 `);
 execFileSync('swiftc',['-parse-as-library','-module-cache-path',join(temp,'cache'),join(temp,'Test.swift'),'-o',join(temp,'test')],{stdio:'inherit'});
 execFileSync(join(temp,'test'),[],{stdio:'inherit'});
} finally {rmSync(temp,{recursive:true,force:true});}
