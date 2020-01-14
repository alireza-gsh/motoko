// test for explicit scope parameterization (disabled for now, uncomment /*<@>*/ once supported)
actor Await {

  public shared func Ack/*<@>*/() : async/*<@>*/ (){
    debugPrint "Ack"
  };

  public shared func Request/*<@>*/(i : Int) : async/*<@>*/ Int {
    debugPrintInt(i);
    return i;
  };

  // Static parallel waiting:

  public shared func PA/*<@>*/() : async/*<@>*/ () {
    let a1 = Ack();
    let a2 = Ack();
    await a1;
    await a2;
  };

  public shared func PR/*<@>*/() : async/*<@>*/(Int,Int) {
    let a1 = Request(1);
    let a2 = Request(2);
    (await a1, await a2)
  };

  // Dynamic parallel waiting for acknowledgements

  public shared func DPA/*<@>*/() : async/*<@>*/() {
   let os = Array_init<?(async ())>(10, null);
   for (i in os.keys()) {
     os[i] := ? (Ack());
   };
   for (o in os.vals()) {
     switch o {
       case (? a) await a;
       case null (assert false);
     };
   };
  };

  // Dynamic parallel waiting (with results)

  public shared func DPR/*<@>*/() : async/*<@>*/ [Int] {
    let os = Array_init<?(async Int)>(10, null);
    for (i in os.keys()) {
      os[i] := ? (Request(i));
    };
    let res = Array_init<Int>(os.len(),-1);
    for (i in os.keys()) {
      switch (os[i]) {
        case (? a) res[i] := await a;
        case null (assert false);
      };
    };
    Array_tabulate<Int>(res.len(),func i { res[i] })
  };

  // Recursive parallel waiting

  public shared func RPA/*<@>*/(n:Nat) : async/*<@>*/() {
    if (n == 0) ()
    else {
      let a = Ack();
      await RPA(n-1); // recurse
      await a;
    };
  };

  // Recursive parallel waiting (with results)

  public type List<Int> = ?(Int,List<Int>);

  public shared func RPR/*<@>*/(n:Nat) : async/*<@>*/ List<Int> {
    if (n == 0) null
    else {
      let a = Request(n);
      let tl = await RPR(n-1); // recurse
      ?(await a,tl)
    }
  };


  public shared func Test/*<@>*/() : async/*<@>*/() {

      await PA();

      switch (await PR()) {
        case (1,2) ();
        case _ (assert false);
      };

      await DPA();

      let rs = await DPR();
      for (i in rs.keys()) {
          assert rs[i] == i;
      };

      await RPA(10);

      var l = await RPR(10);
      for (i in revrange(10, 1)) {
        switch (l) {
          case (?(h, t)) {
            assert (h == i);
            l := t;
          };
          case null (assert false);
        }
      };
  }
};

Await.Test(); //OR-CALL ingress Test 0x4449444C0000


//SKIP comp
