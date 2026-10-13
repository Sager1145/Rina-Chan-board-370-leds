#include "FacesSyncGuard.hpp"
#include <cassert>
#include <iostream>
int main() {
    using namespace facesync;
    State s{"BOARD","LIB","epoch","policy",7,{{"a",2}}, {},0,true,false};
    Candidate n{"BOARD","LIB","epoch","policy",7,{{"a",2},{"b",1}}, {},0,2,1,800,1000,true};
    assert(preflight(s,n)==Result::ok);
    auto t=n;t.board="OTHER";assert(preflight(s,t)==Result::identity);
    t=n;t.epoch="reformatted";assert(preflight(s,t)==Result::identity);
    t=n;t.expectedRevision=6;assert(preflight(s,t)==Result::revision);
    t=n;t.vector={{"a",1},{"b",2}};assert(preflight(s,t)==Result::rollback);
    t=n;t.vector={{"a",2}};t.digest[0]=1;assert(preflight(s,t)==Result::ambiguous);
    t=n;t.faceCount=129;assert(preflight(s,t)==Result::capacity);
    t=n;t.documentBytes=256*1024+1;assert(preflight(s,t)==Result::capacity);
    t=n;t.envelopeBytes=256*1024+1;assert(preflight(s,t)==Result::capacity);
    t=n;t.defaultCount=0;assert(preflight(s,t)==Result::invalid);
    t=n;t.policy="newpolicy";assert(preflight(s,t)==Result::policy);
    t=n;t.vector={{"a",2},{"a",2}};assert(preflight(s,t)==Result::invalid);
    // Projection-local settings: vector equal, settings newer -> allowed even
    // though the digest differs (settings-only redeploy, e.g. startupDefaultId).
    t=n;t.vector={{"a",2}};t.digest[0]=1;t.settings=1;assert(preflight(s,t)==Result::ok);
    // Vector equal, same settings, same digest -> ok (idempotent replay).
    t=n;t.vector={{"a",2}};assert(preflight(s,t)==Result::ok);
    // Vector equal, settings strictly behind -> rollback even if digest matches.
    s.settings=1;t=n;t.vector={{"a",2}};t.settings=0;assert(preflight(s,t)==Result::rollback);
    s.settings=0;
    // Vector strictly newer, settings caught up (>=) -> allowed.
    t=n;t.settings=0;assert(preflight(s,t)==Result::ok);
    // Vector strictly newer, settings still behind -> rollback.
    s.settings=1;t=n;t.settings=0;assert(preflight(s,t)==Result::rollback);
    s.settings=0;
    s.legacyDirty=true;assert(preflight(s,n)==Result::dirty);
    std::cout<<"19 preflight assertions passed (host C++17; no hardware or flash test).\n";
}
