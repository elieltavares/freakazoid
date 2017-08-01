module Freakazoid
  require 'freakazoid/utils'
  
  module Chain
    include Krang::Chain
    include Utils
    
    def reply(comment)
      clever_response = nil
      metadata = JSON.parse(comment.json_metadata) rescue {}
      tags = metadata['tags'] || []
      
      begin
        quote = if comment.body.size > 140
          s = comment.body
          s = s[rand(s.length), rand(s.length - 1) + 1]
        else
          comment.body
        end + ' ' + tags.join(' ')
        
        clever_response = clever.say(quote, comment.author)
      rescue => e
        error e.inspect, backtrace: e.backtrace
        debug 'Resetting cleverbot.'
        reset_clever
      end
      
      if clever_response.nil?
        warn 'Got nil response from cleverbot.'
        return
      end
      
      # We are using asynchronous replies because sometimes the blockchain
      # rejects replies that happen too quickly.
      thread = Thread.new do
        author = comment.author
        permlink = comment.permlink
        parent_permlink = comment.parent_permlink
        parent_author = comment.parent_author
        timestamp = comment.timestamp
          
        debug "Replying to #{author}/#{permlink}"
      
        loop do
          merge_options = {
            markup: :html,
            content_type: parent_author == '' ? 'post' : 'comment',
            account_name: account_name,
            author: author,
            body: clever_response
          }
          
          reply_metadata = {
            app: Freakazoid::AGENT_ID
          }
          
          reply_metadata[:tags] = [tags.first] if tags.any?
          reply_permlink = "re-#{author.gsub(/[^a-z0-9\-]+/, '-')}-#{permlink.split('-')[0..5][1..-2].join('-')}-#{Time.now.utc.strftime('%Y%m%dt%H%M%S%Lz')}" # e.g.: 20170225t235138025z
          
          comment = {
            type: :comment,
            parent_permlink: permlink,
            author: account_name,
            permlink: reply_permlink,
            title: '',
            body: merge(merge_options),
            json_metadata: reply_metadata.to_json,
            parent_author: author
          }
          
          tx = Radiator::Transaction.new(chain_options.merge(wif: posting_wif))
          tx.operations << comment
          
          response = nil
          
          begin
            sleep Random.rand(3..20) # stagger procssing
            semaphore.synchronize do
              response = tx.process(true)
            end
          rescue => e
            warning "Unable to reply: #{e}", e
          end
          
          if !!response && !!response.error
            message = response.error.message
            if message.to_s =~ /You may only comment once every 20 seconds./
              warning "Retrying comment: commenting too quickly."
              sleep Random.rand(20..40) # stagger retry
              redo
            elsif message.to_s =~ /STEEMIT_MAX_PERMLINK_LENGTH: permlink is too long/
              error "Failed comment: permlink too long"
              break
            elsif message.to_s =~ /missing required posting authority/
              error "Failed vote: Check posting key."
              break
            elsif message.to_s =~ /unknown key/
              error "Failed vote: unknown key (testing?)"
              break
            elsif message.to_s =~ /tapos_block_summary/
              warning "Retrying vote/comment: tapos_block_summary (?)"
              redo
            elsif message.to_s =~ /now < trx.expiration/
              warning "Retrying vote/comment: now < trx.expiration (?)"
              redo
            elsif message.to_s =~ /signature is not canonical/
              warning "Retrying vote/comment: signature was not canonical (bug in Radiator?)"
              redo
            end
          end
          
          info response unless response.nil?
          
          break
        end
      end
    end
  end
end
