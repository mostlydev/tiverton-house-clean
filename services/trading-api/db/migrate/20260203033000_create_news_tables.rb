class CreateNewsTables < ActiveRecord::Migration[7.2]
  def change
    create_table :news_articles do |t|
      t.string :external_id, null: false
      t.string :headline
      t.string :source
      t.text :content
      t.text :summary
      t.string :url
      t.datetime :published_at
      t.datetime :fetched_at
      t.string :file_path
      t.jsonb :raw_json, null: false, default: {}

      t.timestamps
    end

    add_index :news_articles, :external_id, unique: true
    add_index :news_articles, :published_at
    add_index :news_articles, :source

    create_table :news_symbols do |t|
      t.references :news_article, null: false, foreign_key: true
      t.string :symbol, null: false

      t.timestamps
    end

    add_index :news_symbols, [:news_article_id, :symbol], unique: true
    add_index :news_symbols, :symbol

    create_table :news_summaries do |t|
      t.string :summary_type, null: false
      t.text :body, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :news_summaries, :summary_type

    create_table :news_notifications do |t|
      t.references :agent, null: false, foreign_key: true
      t.string :symbol, null: false
      t.datetime :notified_at, null: false

      t.timestamps
    end

    add_index :news_notifications, [:agent_id, :symbol], unique: true

    create_table :news_dispatches do |t|
      t.string :batch_type, null: false, default: 'news'
      t.string :status, null: false, default: 'pending'
      t.string :confirmation_token, null: false
      t.text :message, null: false
      t.text :response
      t.text :error
      t.datetime :sent_at
      t.datetime :confirmed_at
      t.jsonb :article_ids, null: false, default: []
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :news_dispatches, :status
    add_index :news_dispatches, :confirmation_token, unique: true
  end
end
