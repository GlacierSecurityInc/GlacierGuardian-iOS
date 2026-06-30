//
//  GRDBModel.swift
//  Glacier
//
//  Created by andyfriedman on 8/22/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation

@objc open class GRDBModel: NSObject {
    
    @objc let uniqueId: String
    var grdbId: NSNumber?
    //var grdbRecord: any GRDBRecord
    
    public override init() {
        self.uniqueId = UUID().uuidString
        //self.init(uniqueId: UUID().uuidString)
    }
    
    public init(uniqueId: String) {
        self.uniqueId = uniqueId
    }
    
    /*public init(uniqueId: String, grdbId: NSNumber) {
        self.uniqueId = uniqueId
        self.grdbId = grdbId
    }*/
    
    @objc static func collection() -> String {
        return NSStringFromClass(self)
    }
    
    /*func updateRowId(rowId: Int64) {
        if (self.grdbId != nil) {
            //Assert(self.grdbId.longLongValue == rowId);
            //DDLogWarn(@"grdbId set more than once.");
        }
        self.grdbId = NSNumber(value: rowId)
    }

    func clearRowId() {
        self.grdbId = nil
    }*/
}
